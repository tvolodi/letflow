# Shared Protocol — Handoff Lifecycle

**Audience:** every agent in Letflow's pipeline.
**Status:** Canonical for handoff *mechanics*. Conflicts with any other document are
resolved by the **Instruction Precedence** chain in
`docs/agents/instructions/core-directives.md` — not by this file claiming to win —
and reported in your handoff `result.issues` at MINOR severity so the drift gets fixed
at the source.

This file exists so the handoff lifecycle is stated exactly once. See
`docs/agents/instructions/core-directives.md` for the broader behavioural rules this
protocol operates inside of (Zero Manual Work, Humanless Operation, Unblock-Everything).

---

## 1. Claim your handoff

At session start, find the handoff addressed to you:

```
handoffs/<RUN-ID>/step-*.json  where  to_agent == "<YOUR_AGENT_ID>"  and  status == "PENDING"
```

```bash
grep -rl '"to_agent": "<YOUR_AGENT_ID>"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Then:
1. Read the file, plus every artefact listed in `context.artifacts_in`.
2. Set `status` to `IN_PROGRESS`.
3. **Do NOT set `started_at` yourself — it is ORCH's, and §1.2 is the whole rule.** §3's
   table assigns the field to ORCH; §1.2 states the procedure, what the field means, and
   the measurement that settled it (ISS-0204). Nothing about it is restated here.
   If the handoff reaches you with `started_at` still null, **leave it null**, do the
   work, and report it in `result.issues` at MINOR so ORCH fixes the dispatch — see
   §1.2's last paragraph for why filling it in is worse than leaving the gap visible.

If no PENDING handoff exists for you and none was named directly by the caller: report
that and stop. Do not invent work — check `docs/requirements.yaml` for the next
`pending` requirement instead, per `docs/agents/ORCHESTRATOR.md`.

## 1.1 A handoff's factual premises are checkable, and may be wrong

`core-directives.md`'s **Instruction Precedence** puts your handoff's `task` block at
rank 1. That makes it the highest authority on **what to do**. It says nothing about the
handoff's **factual claims**, and agents have read it as covering both. It does not: a
handoff is a record written by another agent, and `docs/anti-patterns.md`'s "Inheriting
a claim from a record instead of re-deriving it from the source" applies to it exactly
as it applies to any other record.

**The rule.** When a handoff makes a *checkable factual claim* your work depends on — a
file exists, a path follows a convention, a conflict cannot occur, a count is N — verify
it before building on it. **A verified disagreement outranks the handoff:** report it in
`result.issues`, act on what you measured, and state plainly what you did and why.

**This is not licence to disregard the handoff's instructions.** Instruction Precedence
still governs those, and a **safety/gate rule is never overridable** by anything,
including your own measurement. The distinction is between what you are told to **do**
and what you are told **is true**. Silently complying with a false premise and silently
ignoring a correct instruction are both failures.

**Evidence — twice in one run (WF03-ISS0106-20260821) an ORCH handoff asserted a false
premise, and the receiving agent was right to check rather than comply:**

1. Step 4's handoff named the new test file with a **dotted** filename. TEST-DESIGNER
   found the repo's existing mix-task test is **underscored**, deviated, and *reported
   the deviation* instead of silently complying. ORCH verified and confirmed the handoff
   was wrong.
2. Step Final's handoff asserted that an add/add conflict on the renumbered issue files
   **could not occur**, and that if it did it meant a third concurrent session and must
   be escalated. ELIXIR-DEV checked instead of obeying and showed the reasoning was
   false: a rebase replays commits individually, so the intermediate commit that
   *created* those files collides regardless of a later commit renumbering them. It
   confirmed provenance on both sides before proceeding.

---

## 1.2 `started_at` is stamped at dispatch, by ORCH — the procedure

**This subsection is the single canonical statement of the `started_at` rule.** §1 step 3
and §3's table point here; `ORCHESTRATOR.md` §6 points here; `core-directives.md` does not
state it at all. Do not copy any of it into another file.

**ORCH's procedure, mechanically (all three steps, every dispatch):**

1. Take **one** clock read (§3's command) when you create the handoff file.
2. Write **both** `created_at` and `started_at` from that single value, in the same write
   that creates the file. A dispatch that is written and then sat on is the exception, not
   the rule: if you genuinely create a handoff you do not dispatch immediately, re-read the
   clock and overwrite `started_at` (only) at the moment you spawn the agent.
3. **Do not ask the receiving agent to stamp it in the spawn prompt.** The prompt tells the
   agent to claim the handoff by setting `status` to `IN_PROGRESS`, and says nothing about
   `started_at`. A spawn prompt that asks for it is the defect ISS-0204 was filed against.

**What the field therefore means: the moment the work was DISPATCHED, not the moment the
agent began.** It is a property of ORCH's act, which is why ORCH owns it. Do not read a
`created_at == started_at` pair as a suspiciously eager agent; that is the rule working.
Dispatch-to-first-token latency is not recorded by this schema at all, and nothing here
should be read as an estimate of it.

**Why this direction and not the other — measured 2026-08-21 over the whole corpus for
ISS-0204, not argued.** Both practices were live: §1 said ORCH stamps, while ORCH's spawn
prompts routinely asked the agent to. The corpus was scanned to see which one the files on
disk actually follow:

```bash
python - <<'EOF'
import json,glob,os,collections
from datetime import datetime
g=lambda s: datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ")
b=collections.Counter()
for f in glob.glob('handoffs/**/*.json',recursive=True):
    if os.path.basename(f)=='registry.json': continue
    d=json.load(open(f,encoding='utf-8')); b['files']+=1
    s,c=d.get('started_at'),d.get('created_at')
    if s is None: b['null started_at']+=1; continue
    v=(g(s)-g(c)).total_seconds()
    b['gap<0 (started_at BEFORE created_at)' if v<0 else 'gap==0 (ORCH, one clock read)'
      if v==0 else 'gap 1-30s (ambiguous)' if v<=30 else 'gap>30s (agent-stamped on claim)']+=1
    if v<0 and g(c).second==0: b['  of gap<0: created_at on a round :00 minute']+=1
for k,v in b.items(): print(f"{v:4d}  {k}")
EOF
```

**606 files, 0 unparseable. 10 carry a null `started_at`. Of the 596 with both timestamps:
468 have a gap of exactly zero seconds, 14 a gap of 1-30s, 89 a gap over 30s, and 25 a
NEGATIVE gap.** The discriminator is the gap: ORCH stamping from one clock read at file
creation lands on exactly zero, while an agent that must spawn and read its `artifacts_in`
before claiming cannot get back inside the same second. So ~79% of the corpus is already
ORCH-stamped and ~15% agent-stamped, a 5:1 majority for the rule that was already written.

**AS OF 2026-08-21, at commit `ef62d4b` — and a later re-run will NOT reproduce every
figure, by design.** Those are the counts at the commit that wrote this subsection
(`ef62d4b13427d752aed4553eee1cbf9a479ddea0`, identified from
`git log --oneline -- docs/agents/shared/HANDOFF_PROTOCOL.md`, whose diff is the one that
adds this `## 1.2` heading and the figures paragraph above). Re-run the command — it is
quoted verbatim so you can — but reconcile the result rather than reading a mismatch as a
defect. **Two buckets grow with the corpus:** `files`, and `gap==0`. Every handoff the
pipeline writes adds one file, and under the rule this subsection states it lands at gap
zero. Growth in those two is **expected and exactly reconcilable**: the difference from the
figures above must equal the handoffs written since `ef62d4b`, which you can enumerate by
`created_at`. Twice already: the ISS-0204 gate re-ran it three minutes later and got
607/469 (+1/+1 — its own `WF03-ISS0204-20260821/step-03b-reviewer-gate.json`), and ISS-0207
re-ran it thirteen minutes after that and got 608/470 (+2/+2 — that file plus
`WF03-ISS0207-20260821/step-03-date-scope-figures.json`). Both reconciled to the unit.

**Every other bucket is a fixed historical set, and that asymmetry is what makes this
marker useful rather than merely defensive.** The 25 negative-gap files, the 20 of them on
a round `:00` minute, and the 10 null-`started_at` files are a closed record of defects
already on disk — they are not backfilled (last paragraph of this subsection), and nothing
written under this rule can join them. The 14 and 89 are likewise closed, since agent
stamping is now forbidden outright. So a re-run returning **more** than 608 files and 470
at gap zero is routine growth, while a re-run returning anything other than **10 / 14 / 89
/ 25 / 20** is an **ALARM**, the opposite reading: either the negative-gap class has
recurred — the precise failure this rule was adopted to make structurally impossible — or
the historical corpus has been edited. Do not silently update the figure; find out which.

**And the finding these numbers support is the SHAPE, not the absolute counts.** It is the
roughly 5:1 majority of ORCH-stamped over agent-stamped handoffs, and the existence of a
negative-gap class concentrated on round `:00` minutes. Both survive any amount of corpus
growth, and neither depends on a single count being current. A later reader who reproduces
the shape has reproduced the finding, whatever the totals have drifted to.

**What the discriminator CANNOT distinguish, stated so nobody reads more into it:** (i) an
agent that stamped `started_at` by *copying* `created_at` instead of reading the clock —
indistinguishable from an ORCH stamp, and it would inflate the zero bucket; (ii) an ORCH
that created the file and dispatched some seconds later, versus a very fast agent — the
1-30s band is genuinely ambiguous and is reported as its own bucket rather than assigned
(`WF03-ISS0201-20260821/step-03-riders.json`, agent-stamped per that run's own report, sits
in it at 11s); (iii) it says nothing about *who ought to* write the field, only about who
did.

**The 25 negative-gap files are the corruption case, and they exonerate the receiving
agents.** §1 step 3 used to predict that an agent writing this field would push it *later*
than dispatch. The real defect on disk runs the other way — `started_at` *earlier* than
`created_at`, which is monotonically impossible — and **20 of the 25 have a `created_at`
falling on a round `:00` minute** (e.g. `WF02-REQ051-20260818/step-06-doc-updater.json`:
`created_at 2026-08-18T23:00:00Z`, `started_at 2026-08-18T19:29:00Z`). Round minutes are
what a *fabricated* timestamp looks like; the agents' reads were the honest half of the
pair. The old rationale therefore named the wrong culprit, which is why it has been
replaced rather than kept. This is not a new theory either: `docs/anti-patterns.md`'s
"Extrapolating handoff timestamps instead of reading the clock (ORCH)" records the same
mechanism caught first-hand on a different run, and is not restated here.

**And that is the argument for this direction, not the 5:1 count.** Under this rule the two
timestamps have **one writer and one clock read**, so `started_at < created_at` becomes
structurally impossible rather than merely forbidden — the 25-file class cannot recur. The
weak-model constraint in `core-directives.md` points the same way: the rule now binds the
**one** role that already writes the file and already reads the clock for `created_at`, and
costs the other fourteen roles an instruction each *removed* from their spawn prompts. The
alternative — rewriting §1 and §3 to bless agent-stamping — would have had to keep the
ordering rule alive as prose across fourteen roles and would have preserved the exact
failure class the corpus already contains.

**A null `started_at` on a handoff already in your hands is ORCH's to fix, not yours, and
the historical corpus is not to be backfilled.** The 10 null-`started_at` files stay as they
are: a value invented now for a dispatch nobody can attest to is a worse record than a
visible gap (same reasoning as §4.1(b)'s no-backfill rule, and the same reason §1 step 3
tells you to report it instead of filling it in). This very run's own handoff,
`handoffs/WF03-ISS0204-20260821/step-03-settle-started-at.json`, is one of the ten: ORCH
deliberately left it null so the run would not prejudge the question it was settling.

---

## 2. Handoff file schema

```json
{
  "handoff_id": "<uuid-v4>",
  "run_id": "<run-id>",
  "workflow_id": "<WF-01|WF-02|WF-03|WF-04|WF-05|ADHOC-nnn>",
  "step": "01",
  "from_agent": "<AGENT_ID>",
  "to_agent": "<AGENT_ID>",
  "file": "handoffs/<run_id>/step-01-agent.json",
  "created_at": "<ISO8601-UTC>",
  "started_at": "<ISO8601-UTC or null>",
  "completed_at": "<ISO8601-UTC or null>",
  "status": "PENDING|IN_PROGRESS|COMPLETED|FAILED|ESCALATED|CANCELLED",
  "priority": "HIGH|NORMAL|LOW",
  "context": {
    "stage": "<S0-S8 or null>",
    "requirement_ids": ["<REQ-ID>", "..."],
    "requirement_text": {
      "<REQ-ID>": "<the requirement's full `description` text, copied verbatim from docs/requirements.yaml>"
    },
    "source_text": {
      "<relative/path/to/source>": "<text copied verbatim from that file, when this dispatch depends on the exact wording>"
    },
    "related_handoff_ids": ["<uuid>", "..."],
    "artifacts_in": ["<relative/path>", "..."],
    "owned_modules": ["lib/letflow/...", "..."]
  },
  "task": {
    "description": "<clear, actionable task for the receiving agent>",
    "acceptance_criteria": ["<measurable criterion>", "..."]
  },
  "result": {
    "status": "PASS|FAIL|PARTIAL|BLOCKED|SKIPPED",
    "summary": "<one paragraph>",
    "artifacts_out": ["<relative/path>", "..."],
    "issues": [
      {"severity": "BLOCKER|MAJOR|MINOR", "description": "<description>", "affected_requirement": "<REQ-ID or null>"}
    ],
    "git_evidence": {
      "branch_name": "<feature/<run_id> or null>",
      "commit_sha_list": ["<sha>"],
      "remote_branch": "<origin/branch or null>",
      "push_status": "ok|failed|skipped",
      "pr_url": "<url or null>",
      "pr_create_error": "<error string or null>"
    },
    "next_action": "<suggested next step for ORCH>"
  },
  "rework_count": 0,
  "max_rework": 3,
  "not_agent_attested": {
    "reconstructed_by": "<AGENT_ID, normally ORCH>",
    "reconstructed_at": "<ISO8601-UTC, from the clock at reconstruction time>",
    "reason": "<what happened to the acting agent, and why it could not report>",
    "fields_written": ["status", "completed_at", "result"],
    "evidence": ["<command run> -> <what it established>", "..."],
    "not_verifiable_after_the_fact": ["<what the probes could not settle>", "..."]
  }
}
```

**Exactly two fields in the block above are OPTIONAL — top-level `not_agent_attested` and
`context.source_text`. Every other field is always present.** The two are optional for
unrelated reasons and neither licenses a third: `not_agent_attested` marks a
reconstruction (§4.1), `context.source_text` carries copied source text when a dispatch
has any (see below). Both are OPTIONAL-BY-ABSENCE, so every handoff file written before
either existed stays valid unchanged and still parses against this schema.

**That count is over the FIELDS of this block — not over the MEMBERS of an object inside
it. §4.1(b) is the authority on `not_agent_attested`'s own members, and it admits one
OPTIONAL seventh, `backfill_note`.** The fence above shows that object's six REQUIRED
members only, deliberately: the exception admitting `backfill_note` is SPENT and
authorised exactly one named file (§4.1(b)), so showing the member in the general schema
block would read as an invitation for a second file to acquire it. A linter validating
`not_agent_attested` therefore reads §4.1(b)'s table for that object's member set; one
that derives the set from this fence alone and rejects the one authorised file carrying
`backfill_note` has mis-read this paragraph, not found a defect. "Neither licenses a
third" is a statement about the two OPTIONAL fields of this block and about nothing else.

**`not_agent_attested`** appears ONLY on a handoff *reconstructed* under §4.1(a-2). A
§4.1(a-1) **redispatch does NOT carry it** — the replacement agent did the work it
reports, so its `result` is a genuine first-hand attestation and nothing was
reconstructed. Read "recovered under §4.1" as (a-2) only; stamping this field onto a
redispatched agent's own report asserts the opposite of the truth. Its ABSENCE carries
meaning, date-scoped: see §4.1(b) for exactly what absence asserts and from when, and
§4.1 for who may write the field.

It is shown inside the block rather than as a `//` comment on purpose. **The block above
is valid, machine-parseable JSON and must stay that way** — the placeholders are all
inside double-quoted strings, so `json.loads` on the fence's contents succeeds, which is
what lets a linter (see the Enforcement note) load this schema instead of re-implementing
it. JSON has no comments; anything explanatory about a field goes in prose here, never
inside the fence.

**`context.requirement_text` — written by ORCH, read by everyone else.** ORCH copies each
in-scope requirement's full `description` verbatim from `docs/requirements.yaml` into this
map when it creates the handoff. Receiving agents read the requirement *here*, not by
opening the 61k-token `docs/requirements.yaml` — see `core-directives.md`'s "Load Scoped
Context, Not Whole Files." Listing `"docs/requirements.yaml"` in `artifacts_in` is not a
substitute: it tells the receiving agent to read the whole file, which is the exact cost
this field exists to remove. If a handoff reaches you with `requirement_ids` set but
`requirement_text` missing, that is a malformed handoff — read the named entries with a
targeted `awk`/`Select-String` range (never a full read) and report it as a MINOR issue.

### What goes in `task.description`, and what goes in `artifacts_in`

**This subsection is the canonical definition of the handoff structure rule.** Other files
point here; none of them restates it. Do not re-derive it from "is this dispatch too
long?"

**`task.description` carries the instruction. It does not carry a second copy of a file it
already names.** Concretely:

| Belongs INLINE, in `task.description` / `task.acceptance_criteria` | Belongs as a PATH in `context.artifacts_in` |
|---|---|
| What the receiving agent must do, in the order it must do it | A prior handoff's diagnosis, verdict or evidence |
| The acceptance criteria this step is judged against | A diff, a test report, a log |
| Constraints scoped to *this* step — what is out of scope, what must not be weakened, what a prior step got wrong | An issue record, a decision record, a role or protocol file |
| Which judgements the dispatcher is deliberately leaving to the agent | Any file the agent is going to open anyway |

When content on the right is *also* reproduced on the left, the reproduction is the
defect. Cite the path and state what the agent must do with it — that is the whole
dispatch. A dispatch may say "read `result.summary` in full and implement the six changes
under its 'WHAT A FIX MUST CHANGE' heading"; it may not then also restate the six changes.

**DROPPING A RESTATEMENT IS HALF THE EDIT. THE OTHER HALF IS MANDATORY: the source you
stopped restating MUST appear as a path in `context.artifacts_in`.** This is not a
recommendation and it is not optional — a restatement removed without its path added is
not a shorter dispatch, it is a dispatch missing context, and it is the same defect as
the restatement, pointing the other way. Run this check by name before you complete a
dispatch you have shortened:

> For every source whose text I removed, shortened, or replaced with a mention — including
> one now named only by an ID (`ISS-0113`, `REQ-042`, "the design doc") — is that source's
> relative path present, verbatim, in `context.artifacts_in`?
>
> If any answer is no: add the path, or put the text back. There is no third option, and
> "the agent can find it from the ID" is not one of them.

Naming an ID inline while its record's path is absent from `artifacts_in` fails this
check. So does dropping four restatements and adding one path — count the sources, not
the edits.

**Where copied source text genuinely must travel inside the handoff, it travels in a
structured field keyed by its source — never in `task.description` prose.** That is the
guarantee the `requirement_text` paragraph above makes, and it is unchanged and
undiminished: a receiving agent must never have to open a 61k-token file to learn what it
was asked to build. Two fields carry it, and they do not overlap:

- **`context.requirement_text`**, keyed by `REQ-ID`, for `docs/requirements.yaml` entries.
  Its contract is exactly as stated above — ORCH writes it, everyone reads it, a handoff
  with `requirement_ids` set and `requirement_text` missing is malformed. Nothing here
  changes that. **A value under a `REQ-ID` key is that requirement's `description` and
  nothing else.** The split between these two fields is by FIELD, not by file: any other
  text copied out of `docs/requirements.yaml` — a requirement's `acceptance_criteria`,
  its `depends_on`, its `owner`, or an entry's raw YAML — is not a `description`, does
  NOT get appended under the `REQ-ID` key, and travels in `source_text` keyed
  `"docs/requirements.yaml"`. Concatenating criteria onto a description here breaks the
  one thing this field guarantees: that its value is quotable verbatim as the
  requirement.
- **`context.source_text`**, keyed by source path, for any other cited source whose exact
  wording the dispatch depends on. OPTIONAL, and absent from most handoffs: a dispatch
  that only needs the agent to *act on* a file names it in `artifacts_in` and stops there.
  Use it only when the exact text must be in front of the agent — a clause being amended,
  a line being quoted back — and prefer the smallest excerpt that carries the meaning.

**Weak-model tolerance is preserved in full, and here is how.** `core-directives.md`
requires every dispatch to be explicit and mechanical enough that a weak model still
produces correct work. Nothing above makes any instruction less explicit. No instruction
text is removed, shortened, or made to be inferred: the task, the criteria and the
constraints all stay inline, and the copied source text that used to sit unlabelled in
prose is still present, in a labelled field, in the same file, reachable without opening
anything. The only thing removed is the *second* copy of something the handoff already
names. An agent unsure which side of the table a passage falls on writes it inline — this
rule is never a reason to drop instruction.

**Why this rests on redundancy and not on brevity — read this before restating it as a
length rule, because it is not one.** Measured 2026-08-21 for ISS-0198, first-hand over
`handoffs/` (full figures and method in
`handoffs/WF03-ISS0198-20260821/step-005-01-diagnose.json`):

- Pooled over 69 timed steps in five runs, r(`task.description` chars, step minutes) =
  **0.281** — dispatch length explains under 8% of step-latency variance. "Long dispatches
  make steps slow" is not supported.
- The **shortest**-dispatch run measured (`WF02-REQ113-20260821`, description median 220
  chars) needed 9 rework/regate/rerun steps out of 19 and ran **104.5 minutes**
  wall-clock — *longer* than the 73.2-minute run that prompted the issue, whose median was
  6,608. Rework is the dominant latency term, and under-specification buys it. This is
  what the weak-model constraint predicts, so it is corroboration, not a surprise.
- Of 582 parseable handoff files, **20 have a description over 6,000 chars, and all 20 of
  them name one of their own `artifacts_in` files inside that description.** Not one long
  dispatch is long for any other reason. Cite-and-also-restate is the entire mechanism.

So the case for this rule is that the duplicated copy is unmeasurable, drifts from the
source it was copied from, and buys nothing the citation does not already buy. **The case
is not that shorter is faster — the measurement does not show that, and a rule justified
on it would be correctly discarded by the next agent who checked.** No target length is
stated here or anywhere, and none is to be inferred from the WARN threshold in the
Enforcement note; that threshold selects a tail for reporting, it is not a budget any
dispatch must meet.

**A MEASURED NEGATIVE RESULT — NOT A RULE, AND IT STATES NO THRESHOLD.** Everything in
this block is a measurement of `result.summary`, recorded so the next agent who wonders
whether the rule above should have a result-side counterpart reads the answer instead of
re-running the investigation. **Nothing here constrains the length of any `result.summary`,
no target or budget is stated or to be inferred, and this block must not be cited as a
size rule.** It is the counterpart to the ISS-0198 dispatch-side finding immediately above
because it is the *same question asked of the other half of the file and answered the
other way*. Measured 2026-08-21 for ISS-0200, first-hand over `handoffs/` (full figures,
code and method in `handoffs/WF03-ISS0200-20260821/step-005-01-diagnose.json`):

- Corpus: 605 parseable handoff files, 0 unparseable, across 60 run directories.
  `len(result.summary)`: median 2,986, p90 8,493, p95 12,323, max 47,036, total 2,599,136.
  `len(task.description)` over the same files: median 704, p90 3,940, p95 5,737, max
  19,040, total 889,118. Pooled ratio 2.92x; per-handoff `summary`/`description` ratio
  (n=601) median 3.53x, p90 13.86x, max 43.5x. The result side is the larger half at every
  quantile, and by more than the run that prompted the question had found.
- **The dispatch-side threshold does not transfer, which is itself a reason not to write a
  result-side rule.** The char count H-SIZE-1's WARN uses on the dispatch side — stated
  once, in the Enforcement note, and deliberately not repeated here — selects 4.3% of
  descriptions (26 of 605) but 19.8% of summaries (120 of 605). On this side the same
  number selects the norm, not a tail.
- **Six candidate restatement mechanisms were tested against those 120 large summaries.
  None was supported;** not one summary exceeded 0.30 8-word-shingle overlap on any axis.
  Restating a file named in its own `artifacts_out` (n=35, median 0.059, max 0.264);
  restating its own `issues[]` entries in prose (n=130, median 0.009, max 0.162); a
  validator's summary restating the producer's (n=248 pairs, median 0.002, max 0.200);
  echoing back its own `task.description` (n=120, median 0.002, max 0.069); restating an
  earlier summary in the same run (n=100, median 0.007, max 0.162); restating a file named
  in its own `artifacts_in` (n=119, median 0.018, max 0.264). The structural screen that
  made the dispatch case — naming an `artifacts_in` basename inside the text — fired 20 of
  20 there and only 46 of 120 here, and did not select.
- **METHOD LIMITATION, recorded so this negative result is not over-read.** The 8-word
  shingle test detects verbatim restatement and is under-powered against paraphrase. Run
  against the 26 large *dispatches* — the population ISS-0198 established as true
  positives by reading them — it returns median 0.054, p90 0.200, max 0.347, so it does
  not cleanly separate that side either. These figures are therefore load-bearing only
  comparatively (the result side scores at or below the dispatch side on every axis), and
  the verdict rests additionally on evidence density (large summaries: median 65.3% of
  segments carry a digit, path or identifier; minimum 36.7%) and on a hand-read of the
  least-evidence-dense large summary this metric selects, which restated its
  `artifacts_in` nowhere. **Those density figures are directional and metric-dependent,
  not exact.** An independently written variant of the same metric (segments over 25
  chars, counted if they carry a digit, a path-like token or an `ABC-123` identifier)
  reproduces the direction — large summaries above large descriptions — with different
  absolute values *and* a different least-dense file. Which summary is the hardest case is
  therefore a property of the metric, not a fixed fact about the corpus; do not cite these
  numbers as exact without restating the metric that produced them.

**The asymmetry is the finding.** The dispatch-side defect had two halves: a duplicated
copy *and* an empty structured field the content should have travelled in
(`requirement_text == {}` in 66 of 69). Neither half exists on the result side.
Where `artifacts_out` points at a real produced artefact, the summary does not duplicate
it. (No raw presence count for `artifacts_out` is quoted here, on purpose: ISS-0202
measured that population to be heavily self-referential — handoffs that list their own
handoff file among their outputs — so a bare count is contaminated; and being a presence
count over all steps, including gate steps that correctly produce no artefact, it is the wrong
counterpart to the dispatch side's `requirement_text == {}` either way.) A duplicated copy
is unmeasurable and drifts from the source it was copied from — that was the entire case
for the rule above.
A `result.summary` is an **attestation**: it has no source to drift from, it *is* the
source, and §4 makes the acting agent the only party who can write it. Length bought by
attestation is not the same object as length bought by duplication, and the corpus says
this side is the former. So: no result-side entry in the inline-vs-`artifacts_in` table,
no required shape, no length target.

**Legal `result.status` values — no others:**

| Value | Meaning |
|---|---|
| `PASS` | Work complete, acceptance criteria met |
| `FAIL` | Work attempted, acceptance criteria not met |
| `PARTIAL` | Some criteria met; remainder blocked and listed in `issues` |
| `BLOCKED` | Could not start or continue; blocker named in `issues` |
| `SKIPPED` | Step not applicable to this run (state why in `summary`) |

### Worked examples — what a finished `result` block looks like

Match these shapes. They are the format contract for every role; the differences between
them are the point.

<example name="validator-fail">
A FAIL names every failed check, by acceptance criterion, with the specific gap — never
a general impression. This is what "route back with the specific gaps named" means:

```json
"result": {
  "status": "FAIL",
  "summary": "3 of 6 acceptance criteria unmet in lib/letflow/design/req039-sandbox-pool.md. AC2 (blocking quota wait) has no design element: the doc names claim/1 but never states what happens when all slots are in use. AC4's error shape is 'returns an error' — not a tagged tuple, so ELIXIR-DEV would have to invent it. Section 6 contains a 14-line Elixir function body (claim/1), which this gate fails on sight per WF-02 Step 1b check 2e.",
  "artifacts_out": [],
  "issues": [
    {"severity": "BLOCKER", "description": "AC2: no design element covers the all-slots-in-use path. Design must state the blocking mechanism and the wait-window timeout value.", "affected_requirement": "REQ-039"},
    {"severity": "BLOCKER", "description": "AC4: error shape unspecified. State the exact tagged tuple, e.g. {:error, :invalid_table_name}.", "affected_requirement": "REQ-039"},
    {"severity": "BLOCKER", "description": "Section 6 lines 88-101 contain an implementation body, not a signature. Design artefacts carry signatures and type shapes only.", "affected_requirement": "REQ-039"}
  ],
  "next_action": "Rework CODE-DESIGNER — 3 BLOCKERs above, rework iteration 1 of 3"
}
```
</example>

<example name="validator-pass">
A PASS states what was independently re-derived and how. "Looks good" is not a PASS;
naming the artefact you opened and the check you ran is:

```json
"result": {
  "status": "PASS",
  "summary": "Read lib/letflow/design/req039-sandbox-pool.md directly (not CODE-DESIGNER's summary). All 6 acceptance criteria map to concrete design elements: AC1→claim/1 signature §3.1, AC2→blocking wait §3.2 with 5000ms window, AC3→release/1 + information_schema verification §3.3, AC4→{:error, :invalid_table_name} §4.1, AC5→TRUNCATE-before-insert §4.2, AC6→verbatim moduledoc text §10. No TBD/deferral language (grepped). No .ex bodies present — §6 carries @spec-style signatures only. Cross-module deps listed §7 (Letflow.TenantProvisioning, Ecto.Migrator).",
  "artifacts_out": [],
  "issues": [],
  "next_action": "Route to ELIXIR-DEV (Step 2a)"
}
```
</example>

<example name="security-reviewer-scoped">
SECURITY-REVIEWER records a verdict per invariant, INV-1..INV-8, with APPLIES or
NOT-APPLICABLE stated for each — an unlisted invariant reads as an unrun check:

```json
"result": {
  "status": "PASS",
  "summary": "Scope test: in scope — diff adds priv/repo/migrations/20260818120000_create_tasks.exs. Verdicts against git diff main...HEAD: INV-1 APPLIES (tenant-scoped table) → PASS, tasks table created with prefix: from Ecto.Migration opts, no GLOBAL exception claimed, matches REQ-022 :prefix mechanism. INV-4 APPLIES (config touched) → PASS, no literal secret added; DB URL still read from System.get_env/1. INV-7 APPLIES → PASS, no string interpolation of tenant/user input into SQL; the one interpolated value (schema_name) is validated against ^sandbox_[0-9a-f]{32}$ before use. INV-8 APPLIES → PASS, no unresolved {:ok,_}= on an external-I/O path. INV-2, INV-3, INV-5, INV-6 NOT-APPLICABLE (S4/S5 surface, no API route or response-shaping code in this diff).",
  "artifacts_out": [],
  "issues": [],
  "next_action": "Route to REVIEWER (Step 2d)"
}
```
</example>

<example name="partial">
PARTIAL is for genuinely met-plus-blocked, never for "mostly passed." Say which criteria
landed and what specifically blocks the rest:

```json
"result": {
  "status": "PARTIAL",
  "summary": "5 of 6 acceptance criteria verified by mix test (42 tests, 0 failures — full output in test/reports/report-20260818-WF02-REQ039.yaml). AC3 could not be verified: it asserts the schema no longer appears in information_schema.schemata after release/1, and the sandboxed Ecto connection cannot observe DDL committed by another connection. Not a code defect — a test-harness limitation. Filed as ISS-0031 with a proposed fix (run this one assertion via a checked-out non-sandboxed connection).",
  "artifacts_out": ["test/reports/report-20260818-WF02-REQ039.yaml", "docs/issues/ISS-0031.yaml"],
  "issues": [
    {"severity": "MAJOR", "description": "AC3 unverifiable under the sandboxed test connection; needs a non-sandboxed connection for the information_schema assertion. See ISS-0031.", "affected_requirement": "REQ-039"}
  ],
  "next_action": "ORCH decision: AC3 blocks 'done' for REQ-039 — route to TEST-DESIGNER for the connection fix, do not advance to Step 5"
}
```
</example>

---

## 3. Timestamps come from the clock, never from memory

```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```
```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

Dropping `.ToUniversalTime()` silently emits local time labelled `Z` — nothing in the
output string reveals the mistake, so always call it explicitly. `completed_at` must
never precede `started_at`.

| Field | Who writes it | When | Exception |
|---|---|---|---|
| `created_at` | ORCH | at handoff creation | — |
| `started_at` | **ORCH only** | at dispatch — same write and same clock read as `created_at`, per §1.2 | — |
| `completed_at` | the receiving agent | when it completes the handoff | §4.1 |
| `status` | the receiving agent, from `PENDING`→`IN_PROGRESS` (§1) →`COMPLETED`/`FAILED` (§4). ORCH sets the initial `PENDING`, and sets `ESCALATED`/`CANCELLED` per `ORCHESTRATOR.md` §5 | on claiming and on completing | §4.1 |
| `result` | **the receiving agent, and only the receiving agent** — it is that agent's own attested first-hand report of what it did | when it completes the handoff | §4.1 |
| `task` (including `description` and `acceptance_criteria`) | **ORCH only** — it is the dispatch itself, and the receiving agent **never** modifies it | at handoff creation | — |

**Why the `status` and `result` rows exist, given they look like they are stating the obvious.** They
were added 2026-08-21 (ISS-0117) because they were *not* written down, and the omission
cost more than the rule would have. Until then this table bound only the three timestamp
fields, so "a handoff's `result` is the acting agent's own attested report" — the single
assumption the entire producer/validator gate model rests on — existed nowhere as a rule.
An unwritten rule has no exception clause, so each run that hit a bookkeeping case the
table did not cover improvised its own repair, in a non-schema top-level key invented on
the spot. **Re-derived 2026-08-21** by `json.load`-ing every file under `handoffs/` other
than `registry.json` (550 files, 0 unparseable), subtracting §2's own 17 schema keys, **and
then keeping only the keys that record an out-of-band repair or correction — in practice
the `orch_*`-prefixed ones.** That last filter is not optional: the subtraction alone
returns **26** occurrences in **13** files, because it also catches a `next_action`
misplaced at top level in six files, one stray `gate_history`, and 15 keys across the two
`step-00-git-setup` files that sit on a foreign flat schema. Those are separate faults, not
ad-hoc repair markers, and an agent who re-derives without the filter gets 26 and concludes
this table is wrong.

| Key name | Run | `completed_at` | Shape | Position |
|---|---|---|---|---|
| `orch_timestamp_correction` | `WF02-REQ023-20260816` | 2026-08-16T18:49:40Z | string | 18th/18 |
| `orch_restart_note` | `WF02-REQ027-20260816` | 2026-08-16T21:35:39Z | string | 18th/18 |
| `orch_timestamp_correction` | `WF02-REQ037-20260817` | 2026-08-17T19:45:30Z | string | 11th/18 |
| `orch_reconstruction` | `WF03-ISS0109-20260821` | 2026-08-21T03:29:36Z | object | 18th/18 |

**Four** occurrences, in **four** files, in **four** runs, under **three** names, at
**two** key positions, in **two** shapes. Two of the four were written because the acting
agent stopped existing (`WF02-REQ027`, an infrastructure session limit; `WF03-ISS0109`,
an API error); the other two correct a timestamp, which is an adjacent case this table
also failed to cover. §4.1 is the exception clause those runs were missing.

*The table records the key names **as improvised**. The last row's `orch_reconstruction`
has since been renamed to `not_agent_attested` under §4.1(b)'s single authorised backfill
(2026-08-21, `WF03-ISS0117-20260821`); the other three files are untouched and stay that
way, per §4.1(b)'s no-backfill rule.*

**And the `completed_at` exception pointer is not decorative.** The best-executed repair
so far still violated this table silently:
`handoffs/WF03-ISS0109-20260821/step-final-git-merge.json` carries
`completed_at: "2026-08-21T03:29:36Z"`, byte-identical to its own
`reconstructed_at` (in the key then named `orch_reconstruction`) — i.e. ORCH's clock read, written into a field
this table assigns to "the receiving agent" — and the marker object it added did not
declare that it had done so. The rule was already in force; nothing flagged the breach,
because the marker had no required field obliging the writer to enumerate what it wrote.
That is why §4.1's `fields_written` is mandatory.

**And the `task` row has no exception, because that field was damaged the same way — one
row further along.** A receiving agent that believes its `task` block is wrong, stale or
impossible says so in `result.issues` (per §1.1) and leaves the block alone; ORCH is the
only role that can re-dispatch. During `WF03-ISS0117-20260821` a completing agent replaced
ORCH's **6,290**-character dispatched `task.description` with a **156**-character pointer to
"the PENDING copy of this handoff" — a copy that does not exist, since it is the same file.
Because the file was untracked until that same commit, the dispatched text existed in no git
object and survived only in ORCH's own context, from which it was restored verbatim. The
step's verdict and evidence were unaffected; what was nearly lost was the record of what had
been asked.

---

## 4. Complete the handoff

```
1. Set handoff["status"] = "COMPLETED" (or "FAILED")
2. Fill handoff["result"] per the schema above
3. Set handoff["completed_at"] to the real clock output from step 3
4. Commit handoffs/, and any other files this step produced, to git
   (see core-directives.md's "File Placement Rules" — workflow artefacts are
   committed, not left staged)
```

**Do not write to `handoffs/registry.json` yourself** (updated 2026-08-17,
ISS-0021/GH#78 — step 4 above previously instructed the completing agent to update it
directly, contradicting `ORCHESTRATOR.md`'s "ORCH MUST... maintain
`handoffs/registry.json`", and cost two agents a stop-and-flag decision point across
one run before this was fixed at the source). ORCH updates the matching entry's status
in `registry.json` on your behalf once it receives your completed handoff —
`registry.json` is a single append-only document carrying run-level lock fields
(`owned_modules`, `lock_acquired_at`/`lock_released_at`) only ORCH has the context to
set correctly, and every completing agent writing it directly would be a concurrent-write
hazard across this project's multi-worktree/multi-host setup. Your own handoff file
(steps 1-3 above) is the only file this section asks you to write.

**ORCH: that rule alone does not make your own registry write safe.** It removes the
subagents from the race, not a second ORCH-role session running in the *same* checkout —
which has happened (`ADHOC-20260821-001` / `WF01-TESTPARALLEL-20260821`). The
re-read-before-write, append-only, and single-SHA push rules for that case are in
`ORCHESTRATOR.md` §7.1 and are not restated here.

**Before marking PASS, ask: did I independently verify this, or am I trusting a claim?**
If your role is a validator (see the producer/validator table in `core-directives.md`),
re-derive your verdict from the artefact itself. Reading the producer's own
`result.summary` and echoing it back as PASS is not validation.

---

## 4.1 When the acting agent stopped existing

**This section is the exception to §4 and to §3's `completed_at`/`status`/`result` rows,
and it is the only one.** §4 assumes the agent that did the work is still alive to report
it. Agents in this pipeline die: on an API error mid-response, on an infrastructure
session limit, on a host power outage. **Four such deaths — each of a *dispatched agent
holding an open handoff*, which is this section's class — are on record, in four runs**,
between 2026-08-16 and 2026-08-21, essentially the whole recorded life of the pipeline, and
they drew only **three** different treatments:

| Run | How it died | What was done |
|---|---|---|
| `WF02-REQ027-20260816` | infrastructure session limit, mid-work | redispatched to a fresh REVIEWER |
| `WF02-REQ038-20260817` | connection error, mid-work, zero commits | redispatched to a fresh CODE-DESIGN-VALIDATOR |
| `WF02-REQ043-20260818` | host power outage, mid-rebase | nothing — still `PENDING` on disk today (ISS-0192) |
| `WF03-ISS0109-20260821` | API error, after the merge had landed | ORCH reconstructed the `result` |

Four incidents, three different treatments, one of which was no treatment at all. That
is a recurring class handled ad hoc, so it gets a rule rather than a convention.
Re-derived 2026-08-21 from `handoffs/registry.json`, `handoffs/orchestrator.log` and the
handoff files themselves.

**A boundary fact about this table that a re-derivation will hit.** `WF02-REQ038`'s death is
recorded *only* in `registry.json`'s run note: the dispatch committed nothing, so it left no
handoff file and no `orchestrator.log` line of its own, and a sweep of the handoff files
alone cannot see it.

**The membership test — apply this, not the class name.** An incident is in this section's class when **both** clauses hold, and out when **either**
fails:

1. **A dispatch had been issued** — evidenced by a handoff file addressed to the agent, or by
   an `orchestrator.log` `DISPATCH` line naming it.
2. **The dispatched agent had begun work** — evidenced by an artefact or record *about that
   agent*: a handoff file it wrote or stamped, a commit it authored, an `orchestrator.log`
   line reporting its own progress or verdict, or an explicit statement in `registry.json`
   that it died **mid-work** (or after completing its side effects). ORCH's own `DISPATCH`
   line is evidence of clause 1 and **never** of clause 2.

Clause 2 is the one that does the work, and it is deliberately satisfiable by prose: as
`WF02-REQ038` proves, an agent can die mid-work having produced no file and no commit, so a
test that demanded a file-shaped artefact would exclude a row already in the table. What
clause 2 rejects is a dispatch that was *issued and never taken up* — nothing was left for a
second party to complete, which is the whole subject of §4.1. ORCH's own session dying
*between* dispatches fails both clauses.

**Decide by the test, never by the treatment.** Two incidents can draw the identical
redispatch response and still fall on opposite sides, because redispatch is also what an
unstarted dispatch gets. Re-verified 2026-08-21, all four rows above satisfy clause 2:
`WF02-REQ027` (`registry.json` `/runs/9/step_2d_infra_restart`: "terminated mid-work by an
infrastructure session limit"), `WF02-REQ038` (`/runs/29/note`: "connection error mid-work"),
`WF02-REQ043` (`/runs/34/note`: "Interrupted by a host power outage mid-rebase"),
`WF03-ISS0109` (`/runs/57/note`: "died on an API error AFTER the merge landed").

**Known exclusions — a record of what has been checked, NOT an exhaustive set.** Sweeping
`registry.json`'s prose fields and `orchestrator.log` on their own terms (2026-08-21) placed
two abnormal terminations from the same window outside the class. They are recorded so the
next re-derivation need not re-litigate them. **This is not a claim that no third exists**;
anything newly surfaced is to be tested against the two clauses above rather than checked
against this list.

- **`WF02-REQ025-20260817`** (`orchestrator.log:297`) — the session that died was ORCH's own,
  *between* dispatches, holding no agent handoff. **Fails clause 1.** ORCH resumed the same
  run and finished the work in place, so no `result` was ever left for a second party to
  complete.
- **`WF02-REQ019-20260816`** — **out of class**, and the reasoning is recorded in full because
  this is the case that reads in-class on treatment and out-of-class on the test. Clause 1
  **holds**: `orchestrator.log:49` carries `ORCH -> TEST-RUNNER | Step 4 test run dispatched`,
  and `registry.json` `/runs/2/note` reads "This run was interrupted mid-pipeline when the
  host process exited after Step 4 dispatch, then resumed in a later session from Step 4
  onward". Clause 2 **fails**: nothing records that TEST-RUNNER began. The only artefact is
  ORCH's own — `orchestrator.log:50` (the `RESUME` line) reads "Committed and pushed the
  orphaned Step 4 dispatch log line (commit `2682e06`)", and `2682e06`'s subject is "commit
  orchestrator.log Step 4 dispatch entry from interrupted run", i.e. ORCH committing its own
  dispatch line, not the agent working. `handoffs/WF02-REQ019-20260816/` holds exactly one
  `step04-test-run.json` and it is the **re**-dispatch (`created_at 2026-08-16T05:10:19Z`,
  after the interruption), whose task text states the prior session "was interrupted before
  Step 4 could run". What died was the host process holding ORCH's session — the same shape
  as `WF02-REQ025`. It was then redispatched to a fresh TEST-RUNNER, the identical treatment
  two rows of the table record, which is exactly why treatment cannot decide membership.

Both exclusions fail the test, so **neither is a fifth row and the four-row table above stands
unchanged.**

**This set and §3's four ad-hoc keys are two different sets that happen to be the same
size, and must not be conflated:** two of those four keys correct a timestamp rather than
record a death, and two of these four deaths (`WF02-REQ038`, `WF02-REQ043`) wrote no key at
all.

### (a) Who may complete it — and it is never "nobody"

The answer splits on **whether the step's own side effects finished**, which §4.1(c)
below decides by probe rather than by reading the handoff.

**Case (a-1) — side effects INCOMPLETE: REDISPATCH.** ORCH re-stamps the handoff to
`PENDING` with a fresh clock read and dispatches a **fresh instance of the same role**,
which then does the remaining work and writes its own attested `result` normally. No
`not_agent_attested` marker is written, because nothing was reconstructed — the
replacement agent genuinely did the work it reports.

> **`rework_count` is NOT incremented.** `ORCHESTRATOR.md` §5's counter tracks
> **rejected** work, and nothing was rejected: no verdict was reached, let alone a
> failing one. Spending a `max_rework` budget — which exists to catch a producer
> repeating a mistake — on an infrastructure death would exhaust it against a fault the
> producer had no part in.
>
> This is not a new ruling; it is one that has been sitting in a single handoff file
> instead of in this protocol since 2026-08-16. `handoffs/WF02-REQ027-20260816/step-02d-reviewer.json`'s
> `orch_restart_note` records the first REVIEWER dispatch terminating on a session limit
> mid-work, states "rework_count deliberately NOT incremented" for exactly the reason
> above, and notes that because the dead agent's handoff "was left IN_PROGRESS with a
> null result and was never committed, no partial verdict entered the audit trail." That
> last point is the reason redispatch is clean: a dead agent that reached no verdict
> leaves nothing to contradict.

**Case (a-2) — side effects COMPLETE and irreversible: ORCH reconstructs, under (b).**
When the merge has landed and the branch is gone, redispatch is not merely wasteful, it
is impossible — there is no work left for a fresh agent to do, and its report would be
re-derivation from git exactly as ORCH's would be, but carrying the additional false
implication that the acting agent reported it. So **ORCH, and only ORCH, completes the
handoff**, marked per (b). ORCH-only here follows the same ownership logic as §4's
registry rule: the reconstruction is a run-level act of bookkeeping, and splitting it
across roles is how ISS-0021's who-owns-what contradiction happened.

**Exactly three fields are ORCH's to write here — the same three §3's table sends to this
section, and no others:**

1. **`status`** — to `COMPLETED` or `FAILED`, per §4 step 1.
2. **`completed_at`** — a **fresh clock read taken at reconstruction time**, per §3. Never
   an estimate of when the dead agent would have finished, and never back-dated to the
   side effect's own timestamp; the honest value is when the repair happened.
3. **`result`** — the reconstructed block itself.

**All three MUST appear in (b)'s `fields_written`.** Writing `result` alone and leaving
`status` at `PENDING` with `completed_at` null is not a partial repair — it reproduces
exactly the defect the next paragraph rejects by measurement. `started_at` is **not** on
this list and is not rewritten: ORCH already stamped it at dispatch and it is still true.

**Why "leave it `IN_PROGRESS`/`PENDING` forever and file a separate incident record" is
rejected — by measurement, not by preference.** That option has been executed, and its
cost is on disk: `handoffs/WF02-REQ043-20260818/step-final-git-merge.json` has read
`status: PENDING` with `completed_at: null` and a null `result` since 2026-08-18, for a
run that squash-merged to `main` as `e25822a` via PR #174. The audit trail is not merely
incomplete there — it actively asserts something false, and the truth survives only
inside a prose note in `registry.json`. An audit trail that lies is worse than one that
says "this was reconstructed, here is by whom and from what."

*That specific file is filed as ISS-0192 and is deliberately not repaired by this
amendment; this section is what governs its later repair.*

**ISS-0192's second file is NOT in this section's class, and must not be repaired under
it.** `handoffs/WF02-REQ062-20260819/step-03-test-designer.json` also reads
`status: "PENDING"`, but ISS-0192 itself says why that is a different fault: TEST-DESIGNER
performed §4's steps 2 and 3 and skipped step 1. Measured 2026-08-21, the file carries
`completed_at: "2026-08-19T05:25:43Z"` and a full `result` with `status: "PASS"` — the
acting agent's own attested report. It is a plain §4 step-1 omission needing a `status`
correction only. Applying (a-2) to it would stamp `not_agent_attested` onto a result that
**was** agent-attested, asserting the precise falsehood the field exists to prevent. A
null `result` is what puts a handoff in this section's class; a bare `PENDING` is not.

### (b) The mandatory marking: `not_agent_attested`

A handoff completed under (a-2) **MUST** carry a top-level field named exactly
`not_agent_attested`, an object with **the six REQUIRED members below, and at most the one
OPTIONAL member `backfill_note`**. Not a convention, not a sentence in `result.summary`, not
a key name chosen at the time of writing.

| Member | Contents |
|---|---|
| `reconstructed_by` | the `AGENT_ID` that wrote the block — normally `ORCH` |
| `reconstructed_at` | clock-read UTC timestamp, per §3 |
| `reason` | what happened to the acting agent and why it could not report |
| `fields_written` | **the explicit list of fields this writer authored**, e.g. `["status","completed_at","result"]` |
| `evidence` | the commands run and what each one established — one entry per command |
| `not_verifiable_after_the_fact` | an explicit list of what the probes could not settle. Never an empty implication; if genuinely nothing, say `[]` deliberately |
| `backfill_note` **(OPTIONAL — the only one)** | present **only** on a file amended under this subsection's single named exception below: what was renamed or added, by which run, and the attestation that no factual assertion changed. Admissible on no other file |

**The member set is CLOSED at those seven, and `backfill_note` is the only optional one.** A
member that is neither required nor `backfill_note` is a defect, not an extension — that is
the point of enumerating them, and it is what lets ISS-0191's linter reject a misspelled or
junk key. Two alternatives were considered and rejected when the ISS-0109 backfill first
exposed the gap: reading "six" as a required *minimum* was rejected because it converts a
closed enumeration into an open one and costs the linter exactly that ability; folding the
content into `reason` was rejected because `reason` states why the **result** is unattested
while `backfill_note` states why the **marker** was applied retroactively, and merging them
collapses the reconstruction-versus-measurement distinction inside the one file whose whole
purpose is preserving it.

**And the exception that admits `backfill_note` is SPENT.** It authorised one named file
(below) and no other, so **no further handoff can acquire this member** — a second file
carrying it would be a marker retro-fitted under an authorisation that no longer exists,
which is precisely what the no-backfill rule forbids.

**It is OPTIONAL-BY-ABSENCE — and the absence is date-scoped, because it has to be.** It
appears only on a handoff reconstructed under (a-2). **Every handoff file predating this
rule remains valid unchanged**, and **no backfill is required or wanted** — a marker
retro-fitted to a file nobody can now attest to would itself be an unattested claim.
(Stated without a headcount deliberately: that number grows every run, so any figure
written here is wrong by the next one.)

**What absence asserts, and from when — scoped to the landing COMMIT, not to its day.** On
a handoff created **at or after commit `131aba9`** (committed 2026-08-21T12:13:08+05:00 =
`07:13:08Z`), the commit this rule landed in, absence of `not_agent_attested` asserts that
the `result` is the acting agent's own report — precisely the assertion §3's `result` row
makes into a rule. On a handoff created **before** that commit, absence asserts **nothing**:
those files were never audited against a rule that did not exist, so absence there means
only "the rule did not exist yet."

**Day granularity would be false, and measurably so, which is why the boundary is a
commit.** Measured 2026-08-21: 46 handoff files carry a `created_at` on 2026-08-21, and **42
of them predate `131aba9`** — including
`handoffs/WF03-ISS0109-20260821/step-final-git-merge.json` (`created_at`
`2026-08-21T03:24:18Z`), the repository's single genuine (a-2) reconstruction and the one
file this subsection singles out below. A same-day boundary would therefore have asserted,
of that exact file, that its `result` was the acting agent's own report: the precise
falsehood this field exists to prevent. The backfill below closes that one file; the other
41 are closed only by scoping the boundary correctly.

**One backfill was authorised — exactly one, and it has now been performed.**
`handoffs/WF03-ISS0109-20260821/step-final-git-merge.json` is the single genuine (a-2)
reconstruction in the repository, and it carried `orch_reconstruction`. Before the rename,
`grep -rl not_agent_attested handoffs/` returned only files that *discuss* the field and not
that one — so without this exception, the command offered below as the field's whole
justification would have enumerated **zero** of the one reconstruction that exists, and done
so permanently. The rename to `not_agent_attested` (with `commands_run` → `evidence`, and
`fields_written: ["status","completed_at","result"]` added, which §3 establishes ORCH did
write and did not declare) landed 2026-08-21 in run `WF03-ISS0117-20260821`, and the file
records it in a `backfill_note` member. It was a **key rename over evidence already present
in the file and already ORCH's own** — verified by diffing the file's parsed structure before
and after, which shows zero changed values on common paths and nothing lost — and **not** a
claim retro-fitted to a file nobody can attest to, which is what the no-backfill rule rightly
forbids in general. **No further backfill is authorised by this exception**; it named one
file and is spent.

**Why a required field rather than a convention — the measurement, not the argument.**
The convention — *annotating an out-of-band bookkeeping repair in a top-level key invented
on the spot, for a case §3's table did not cover, of which reconstruction is one member* —
was tried, without anyone deciding to try it. **Not all four instances below are deaths**
(§3's table splits them: two are deaths, two are timestamp corrections); what makes them one
family is the improvised naming, and that is what this measurement is about. §3's table above
is the measurement, re-derived 2026-08-21 over every file under `handoffs/`: **four** occurrences,
in **four** files, in **four** runs, under **three** key names, at **two** key positions
(18th/last in three files, 11th/mid-file in one), in **two** shapes.

The shape figure is the one that settles it, and the ordering matters. Sorted by
`completed_at`: **three string-shaped uses inside 25 hours** (2026-08-16T18:49:40Z,
2026-08-16T21:35:39Z, 2026-08-17T19:45:30Z), and then, **three days later**, an object
(2026-08-21T03:29:36Z). So the shape held long enough for two later writers to reproduce
it, and was then silently replaced by a fourth who had no way to know the other three
existed. That is not a convention converging on a form; it is four agents each solving the
same problem alone, and the fourth one's improvement — a structured object with an
evidence list, which is strictly the best of the four — is invisible to every writer
before it and to any reader who greps for the wrong name.

**And a written rule is necessary but NOT sufficient — say so rather than pretend
otherwise.** §2's `status` enum *is* written down, and — re-derived 2026-08-21 by the same
scan as §3's table — **15** handoff files on `main` violate it: **13** carry `"PASS"`, a
`result.status` value, in the handoff's own `status` field, and **2** have no top-level
`status` key at all and sit on a foreign flat schema. Writing
this down will not by itself produce compliance. What a *named field* buys over prose is
that the violation is **greppable**: `grep -rl not_agent_attested handoffs/` enumerates
every reconstructed handoff in one command, and a linter can assert over the field's
shape. Prose in a summary is findable by nobody and checkable by nothing — and the
proof is `handoffs/WF03-ISS0109-20260821/step-final-git-merge.json`, whose repair was
otherwise exemplary: after it, **nothing in `status`, `completed_at`, `result.status` or
`result.artifacts_out` distinguishes that file from a normal completion.** Only free-text
prose and a non-schema key do. A weak model that omits the prose leaves a reconstruction
indistinguishable from a measurement, which defeats the audit trail entirely.

`fields_written` is the member not to drop. That same exemplary repair reconstructed
`completed_at` without declaring it (see §3), so the one field whose ownership the
protocol *had* already assigned was the one silently taken.

### (c) Died MID-action vs died AFTER acting — decide by probe, never by judgement

These need materially different paths — (a-1) and (a-2) above — and **the two are
indistinguishable from the handoff file itself.** This is the hard part, and the evidence
says so directly:

- `WF02-REQ043-20260818` — host power outage **mid-rebase**, branch left mid-rebase
  (corroborated by ISS-0046, whose `discovered_in_run` names this run and this step).
- `WF03-ISS0109-20260821` — API error **after** the merge had already landed.

**The predicate is evaluated at REPAIR time, not at death time**, and that is why the same
run can appear on both sides of this section. `WF02-REQ043-20260818` died *mid*-rebase, so
at the moment of death it was case (a-1) — which is why it appears in the bullet above as
the mid-action exemplar. Its side effects have since completed (`e25822a`, verified
2026-08-21 as an ancestor of `main`), so a repair attempted *today* evaluates the
predicate to satisfied and is case (a-2) — which is why (a-2) cites it too. Both citations
are correct and they are not in tension: "is there work left for a fresh agent to do" is a
question about now, never about then. Evaluate the probes when you repair, and classify
from what they return.

**On disk these two presented identically: a handoff with a null `result`.** They needed
opposite treatments. So the discrimination is a **MANDATORY PROBE OF THE STEP'S DECLARED
SIDE EFFECTS**. It is never a judgement call, and it is never read off the handoff's own
contents — the handoff records only what the agent *intended* to do, and an agent that
died mid-action intended everything.

**Worked example — the probe set for a git step**, lifted verbatim from
`WF03-ISS0109-20260821`'s own `not_agent_attested.evidence` (written as
`orch_reconstruction.commands_run`, renamed by the backfill above), which is where this
was first done properly:

```bash
ls .git/rebase-merge .git/rebase-apply          # a mid-rebase leaves these behind;
                                                # their ABSENCE is the most direct
                                                # mid-action discriminator there is
git status --short && git branch --show-current # clean tree? which branch?
git fetch origin
git rev-list --left-right --count origin/main...HEAD   # 0 0 => HEAD is exactly origin/main
git ls-remote --heads origin <branch>           # empty => remote branch deleted (cleanup ran)
gh pr view <n> --json state,mergedAt,mergeCommit # MERGED + a mergeCommit sha => it landed
```

**Generalised, for step types that are not git steps:** every step type declares an
**idempotent completion predicate** over its own side effects — the files it was to
write, the rows it was to insert, the artefacts it was to produce — and the
mid-vs-after classification is the **output of evaluating that predicate**, not an input
to it. All side effects satisfied ⇒ case (a-2). Any side effect unsatisfied ⇒ case (a-1).

Two constraints, both stated because omitting either is how this goes wrong:

1. **INDETERMINATE FALLS TO REDISPATCH (a-1).** Not to reconstruction, and not to a
   judgement call about which is more likely. The asymmetry is what decides it:
   redispatching an already-complete idempotent step costs one agent turn and changes
   nothing, while attesting to an incomplete one puts a **false PASS into the audit
   trail** — the one failure this whole section exists to prevent, and the one nothing
   downstream can detect.
2. **What the probes cannot settle goes into `not_verifiable_after_the_fact`, never
   omitted.** `WF03-ISS0109-20260821` did this correctly — it listed the two questions
   git cannot answer after the fact (whether the rebase hit any conflict, since a clean
   rebase leaves no trace; and whether `git stash` was used) — and it is the single
   practice from that incident most worth making mandatory, because **silence about an
   unverifiable thing reads as verification.** A reader cannot tell an unasked question
   from an answered one.

### (d) Record it at the run level too

A recovered handoff is also a fact about the *run*, and a reader scanning
`handoffs/registry.json` must be able to tell a clean run from a recovered one without
opening every step file. See `ORCHESTRATOR.md` §7.2 for the `recovered` /
`recovery_note` fields and for which of the two registry mechanisms (amend in place vs.
append a `-resume` entry) applies when.

---

## 5. The audit trail is append-only

`handoffs/orchestrator.log` and `handoffs/registry.json` record what the pipeline did
and why. They must never shrink. Open the log in append mode; never regenerate it
wholesale. A commit that reduces either file's size is a defect to flag, not a cleanup
to perform.

---

## 6. Never satisfy a gate by editing what it measures

If a gate blocks you, fix the condition it detects. Never make the detector stop
reporting — see `core-directives.md`'s fuller statement of this rule and its rationale.

---

## 7. Workspace hygiene

- Pre-existing unrelated uncommitted changes are expected context, not a blocker.
  Continue, keep your edits scoped to your handoff's targets. Stop only for true file
  overlap on your own targets.
- Commit workflow artefacts (`handoffs/`, `lib/letflow/design/`, `docs/issues/`,
  `docs/status/`) before completing — they are the project's audit trail.
- Scratch files go in `scratch/` (git-ignored). Never in the project root or a tracked
  directory.

---

## Enforcement note

R-Co enforces this protocol mechanically via `tools/lint_handoffs.py` (schema
conformance, timestamp monotonicity, encoding, registry coverage) after a 2026-08-05
pipeline audit found unenforced bookkeeping rules were followed at 0.4-8.6% compliance
despite being written down. Letflow does not have an equivalent linter yet — this is a
known gap, not an oversight. Until one exists, every validator role and ORCH itself must
manually check handoff files for schema/timestamp violations as part of its own gate,
per its role file. Building a `mix letflow.lint_handoffs` task (or a plain script, per
the precedent in `docs/anti-patterns.md`'s Mix-task-discovery-cost finding) is worth
raising as its own requirement once the pipeline has run enough cycles to show whether
Letflow drifts the same way R-Co did.

### Specified but NOT YET RUNNING — H-SIZE-1/2/3 (added 2026-08-21, ISS-0198)

**None of these three checks runs today, and nothing in this file should be read as
saying otherwise.** They are specified here, where the linter's spec lives, so that
whoever builds it implements them without judgement. ISS-0191 (the linter) is open and
unbuilt, and names ISS-0190's 15+13 existing schema violations as a likely prerequisite —
a size check added to that scope will not run green until ISS-0190 is cleared. Until the
linter exists these are a specification and a manual reading aid, not a gate, and no
handoff passes or fails on them.

Per handoff file, using only `json.load`, `len`, substring search and `basename` — no
repo state, no cross-file reads, no NLP, no judgement:

```
desc  = task.description or ""
acs   = task.acceptance_criteria or []
names = { basename(p) for p in (context.artifacts_in or []) }

H-SIZE-1  WARN  "cite-and-restate"
          len(desc) > 6000  AND  any(n in desc for n in names)

H-SIZE-2  WARN  "under-specified"
          len(desc) + sum(len(ac) for ac in acs) < 400

H-SIZE-3  INFO  per run, never fails
          emit: n_steps, median/max/total len(desc), count of H-SIZE-1 hits
          emit also (added 2026-08-21, ISS-0200):
                median/max/total len(result.summary), and the per-step
                summary/description ratio.
                REPORT ONLY. No threshold, no WARN, no pass/fail, on either
                figure -- a threshold here would be a length rule on
                result.summary by the back door, and no such rule exists.
```

**6,000 is a WARN threshold, not a length any dispatch is required to meet.** It is set
from the corpus, measured 2026-08-21 over 582 parseable files: p90 = 3,191, p95 = 5,138,
max = 12,187, median = 682. 6,000 sits above p95 and selects 20 files (3.4%) — the tail,
not the norm — and every one of those 20 is a true positive under the structure rule in
§2. Moving the threshold changes how much tail is reported; it does not change the rule,
because the rule states no length.

**H-SIZE-2 is why the structure rule cannot be satisfied by truncation.** It fires on a
dispatch that is short because it under-specifies, which the ISS-0198 measurement found is
the failure mode that actually costs wall-clock (9 rework/regate/rerun steps out of 19 in
the shortest-dispatch run measured). A fix that deleted instruction text to quiet H-SIZE-1
would light up H-SIZE-2.

**Both WARN checks are advisory by design.** Neither condition proves a defect on its own,
and a hard failure on either could be bought by deleting text — which §6, "Never satisfy a
gate by editing what it measures," forbids. H-SIZE-3 is a per-run report and is the
mechanism that would notice this drift recurring: the ISS-0198 measurement found 36 of the
45 corpus files over 4,000 chars belong to five runs dated within a single day, so it is
recent drift rather than a standing property of the pipeline.

**The `result.summary` figures H-SIZE-3 emits are reporting only, and H-SIZE-3 does not
run today either** — the "None of these three checks runs today" framing at the head of
this section covers the extension exactly as it covers the rest. They were added by
ISS-0200, whose measured negative result is recorded in §2: no result-side restatement
mechanism exists in the corpus today, so there is nothing for a check to gate on, and a
WARN would be a length rule on `result.summary` by the back door. The figures exist so
that if the result side ever *does* acquire such a mechanism, the drift is visible without
a fresh investigation.
