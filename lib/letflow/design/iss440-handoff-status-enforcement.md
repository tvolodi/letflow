# ISS-0440 — Handoff top-level `status` enum enforcement (design)

**Author:** CODE-DESIGNER, WF03-ISS0440-20260903 Step 2.
**Input:** ISSUE-FIXER's Step 1 diagnosis
(`handoffs/WF03-ISS0440-20260903/step-01-issue-fixer-diagnosis.json`), verified against
`lib/mix/tasks/letflow.lint_handoffs.ex`, `mix.exs`, `.github/workflows/ci.yml`, and
`docs/anti-patterns.md` directly rather than inherited.
**No implementation code below** — signatures, data shapes, and control flow only, per
CODE-DESIGNER's mandate. `.ex` bodies are ELIXIR-DEV's job.

---

## 0. The property this design is judged against

Six prior mitigations were prose: "ORCH should grep the handoff", "run the linter before
declaring done", "a pre-push hook could…". All six were something an agent had to *choose*
to do, and all six were skipped at least once. ISSUE-FIXER named the discriminator:

> the check must fire as a mechanical consequence of an action the pipeline cannot avoid
> taking, with zero agent decision about whether to run it.

This design answers that question first, states which unavoidable action each of the two
mechanisms it adopts rides on, and only then works through the four candidates and the five
acceptance criteria.

**One distinction this design must not blur, because blurring it is exactly how a seventh
mitigation becomes an eighth tally line: "unavoidable" is not one uniform property across
the two mechanisms this design adopts.** §1.1's CI gate is **structurally
(code/infrastructure) enforced** — GitHub Actions runs the workflow on its own trigger,
independent of any agent's memory, and a red `mix letflow.check` structurally cannot merge.
§1.2's ORCH dispatch-time commit is **procedurally enforced** — a documented MUST that ORCH
has followed with a strong track record (§1.2 states the evidence), but it is still prose
an agent executes, not something code forces ORCH to do. This design keeps both mechanisms
and is explicit throughout about which class each belongs to, rather than presenting both
as the same strength of guarantee. §1.2 states this in full for Mechanism B; §3.5 draws the
consequence: only Mechanism A carries the structural guarantee, and the pair's value is
that B adds an early, procedurally-reliable catch on top of an unconditional CI backstop —
not a second independent guarantee.

---

## 1. The two unavoidable actions this design rides on

### 1.1 Unavoidable action #1 — `mix letflow.check` runs on every push, unconditionally, host-agnostic

`.github/workflows/ci.yml`'s `backend` job's only content step is `run: mix letflow.check`
(no flags, no conditional). `mix.exs`'s `letflow.check` alias (lines 91-108, verified read
this session) is a **fixed, non-optional list**:

```
letflow.check_toolchain
letflow.check_requirements_registration
letflow.check_deferral_staleness
letflow.lint_handoffs          <- already here, unconditionally, today
format --check-formatted
compile --warnings-as-errors
letflow.check.test
```

There is no agent decision anywhere in this chain: GitHub Actions runs the job on every
`push`/`pull_request` event by workflow trigger, not by an agent choosing to invoke it, and
the alias is a straight-line Mix list — Mix does not skip a list entry because an agent
forgot to ask for it. **A PR cannot merge in this pipeline without this job going green**
(WF-02 Step Final / `GIT_MERGE.md`'s CI-green gate is itself a hard, unconditional
precondition, not a discretionary check). This is the strongest unavoidable action available
in the whole pipeline, because it requires no per-host setup at all — it runs in GitHub's own
runner image, not on any agent's workstation.

This is why §2's autofix change rides here and nowhere else: it does not need a new call
site. `mix letflow.lint_handoffs` already executes on this path today; the only change is
what it does with a bad value it finds, and only for the closed, verified-safe subset.

### 1.2 Unavoidable-in-practice action #2 — ORCH's dispatch-time handoff commit (`HANDOFF_PROTOCOL.md` §1.3), a PROCEDURAL not a CODE guarantee

**Correction from this design's first iteration, made explicit here per CODE-DESIGN-VALIDATOR's
rework-1 finding.** §1.3 is itself prose: "the moment ORCH writes a `PENDING` handoff file,
it commits that file... before spawning the receiving agent... every dispatch, every time"
is a documented MUST (`ORCHESTRATOR.md:23`'s MUST list points at it) that ORCH executes by
following written instructions — nothing in the toolchain forces ORCH to run
`git add && git commit` before spawning the next agent. **This design's first draft claimed
"there is no path through this procedure that reaches step 4 without having passed step 2"
— that claim is not literally true and is withdrawn.** A future ORCH session could, in
principle, skip the read the same way it could skip the commit itself: nothing but the
written procedure stops either.

**What is true, and is the actual basis for adopting Mechanism B: §1.3 has a strong,
verified track record, not a structural one.** `docs/anti-patterns.md:1123` records the
single incident that *caused* §1.3 to be written (a dispatched handoff sat untracked in the
working tree, and the record of what was asked existed in no git object until the receiving
agent's own later commit) — and no recurrence of that specific failure is logged since. This
run's own unsquashed branch shows the real dispatch-then-complete pattern live: commit
`45ac032a` (ORCH's dispatch) followed by `dc7431b9` (CODE-DESIGNER's completion) — two
separate, ordered commits, exactly the shape §1.3 describes. (CODE-DESIGN-VALIDATOR also
found that `main`'s own history is the wrong place to verify this from directly, because
squash-merges collapse a run's internal commit sequence — an apparent "88.5% single-commit"
figure on `main` is a squash artifact, not evidence against §1.3 compliance; the
unsquashed branch is the correct place to look, and it confirms the pattern.)

**So: Mechanism B inherits §1.3's *reliability class* — strong track record, procedurally
enforced, not code-guaranteed — and this design states that plainly rather than implying
CI-gate-strength unavoidability.** The relevant asymmetry, still true and still the reason
this mechanism is worth having despite being procedural: verified this session against
ISSUE-FIXER's own count, **all 8 occurrences were written by the *completing* agent, never
by ORCH authoring its own handoff.** The read this design adds does not ask the
error-prone party to catch itself; it asks ORCH — a party with a clean record on this
specific defect, executing a procedure with its own clean record since ISS-0196 — to read
a file *before* an action ORCH already reliably performs (the pre-dispatch commit). See §3
for exactly where in that existing procedure the read is inserted, and §3.5 for the
consequence of B being procedural rather than structural: it is not, on its own, what makes
the violation "structurally impossible" — that word is earned by Mechanism A alone (§1.1),
and B's honest role is a latency improvement layered on top of it, not a second independent
guarantee.

---

## 2. Mechanism A — restricted `--autofix` on `mix letflow.lint_handoffs`, riding action #1

### 2.1 Scope, precisely

Extends `Mix.Tasks.Letflow.LintHandoffs` with two new, independent, orthogonal flags on
its existing single entry point.

```
@spec run([String.t()]) :: :ok
```

`run(_args)` currently ignores its argument entirely (confirmed at line 233/234 this
session — the body calls `handoff_files/0` with zero arguments, never touching the bound
parameter). This design requires `run/1` to actually parse `args` for two flags:

- **`"--autofix"`** — enables Mechanism A's corrective behaviour, per §2.2 below.
- **`"--dir <path>"`** — overrides which directory is scanned, addressing
  CODE-DESIGN-VALIDATOR's rework-1 finding (BLOCKER 2) that AC1's demonstration cannot
  execute today because `run/1` never threads anything into `handoff_files/1`'s
  already-parameterized `dir` argument (verified at line 279:
  `def handoff_files(dir \\ @handoffs_dir)` — the capability already exists one layer down,
  it is simply unreachable from the CLI).

**Default-preserving contract, stated explicitly since CI depends on it:** `run([])` (no
flags at all — CI's exact invocation, `mix letflow.check`'s alias entry
`"letflow.lint_handoffs"`, unchanged) must resolve to `handoff_files(@handoffs_dir)`,
byte-for-byte the same call CI makes today. This means:

```
@spec resolve_dir([String.t()]) :: String.t()
# no "--dir" present in args -> returns @handoffs_dir (the literal "handoffs"),
# unchanged from today's hardcoded default.
# "--dir" present -> returns the next arg verbatim, no validation beyond
# "the flag has a following argument" (a missing value is a usage error,
# reported and non-zero exit, not a silent fallback to @handoffs_dir --
# a silent fallback would let a typo'd --dir invocation quietly re-lint the
# real corpus and misreport what was actually checked).
```

`run/1`'s body becomes: parse `args` for both flags (order-independent — `--dir` and
`--autofix` may appear together or separately, since AC1's demonstration needs exactly
that combination in step 3 below), resolve the directory via `resolve_dir/1`, call
`handoff_files(dir)` instead of today's zero-arg `handoff_files()`, then proceed exactly as
today (or, if `--autofix` is set, via §2.4's autofix path) over that file set.

**Confirmation this cannot change CI's no-flag behaviour:** CI's only invocation is
`mix letflow.check`, which runs the alias entry `"letflow.lint_handoffs"` — a bare Mix task
name with **no arguments appended**, unchanged by this design. A bare invocation parses an
empty `args` list, `resolve_dir([])` returns `@handoffs_dir` exactly as the current
hardcoded default does, and no `--autofix` means the corrective branch (§2.4) never
executes. CI's path is therefore identical in behaviour to today's, by construction — the
new flags are strictly additive surface `run/1` exposes for local/test invocation, not a
change to what CI does.

### 2.2 The mapping, closed, no fifth case

| Found top-level `status` value | Autofix action |
|---|---|
| `"PASS"` | rewrite to `"COMPLETED"` |
| `"COMPLETE"` | rewrite to `"COMPLETED"` |
| `"DONE"` | rewrite to `"COMPLETED"` |
| `"FAIL"` | **refuse** — do not rewrite, report as an unresolved H1 violation exactly as `--autofix` were absent |
| any other non-enum string, or missing/non-string `status` | **refuse** — same as `FAIL` |

This mapping is not a heuristic scored at runtime — it is the literal closed set
`{"PASS", "COMPLETE", "DONE"}` mapping to the single literal `"COMPLETED"`, matching every
independently-verifiable historical fix ISSUE-FIXER found (0 counterexamples across 3
recoverable fix commits) and covering none of the ambiguous case. A new data structure
(name suggested, not prescribed):

```
@spec autofix_map() :: %{String.t() => String.t()}
# %{"PASS" => "COMPLETED", "COMPLETE" => "COMPLETED", "DONE" => "COMPLETED"}
```

`"FAIL"` MUST NOT appear as a key anywhere in this map, and must not be added to it later
without re-deriving the ambiguity question — this is an explicit open question boundary
(§6.1), not an oversight.

### 2.3 Refusal behavior, stated so the caller has a concrete contract

`--autofix` never silently drops a violation and never silently "fixes" an ambiguous one.
Its contract:

- **Fixed** (safe subset): the file is rewritten in place (`status` field only — no other
  field touched), the fix is reported to stdout by path and by old→new value, and the file
  is **removed from the hard-violation count** for that run (it was corrected, not
  grandfathered).
- **Refused** (`FAIL` or anything unrecognized): the file is **left untouched**, reported to
  stdout distinctly from a fixed file (e.g. under a `REFUSED — REQUIRES HUMAN-EQUIVALENT
  DECISION` heading, not lumped with `NEW HARD VIOLATIONS`), and **still counts as a hard
  violation** for exit-code purposes — `--autofix` never turns a `FAIL`-shaped file into a
  passing run. The message names the file, the literal value found, and states explicitly:
  *"`FAIL` is ambiguous between a lifecycle `FAILED` handoff and a `COMPLETED` step with a
  failing `result.status` — this tool will not guess; correct the top-level `status` field
  by hand."*

This is the concrete answer to the handoff's "state what the refusal looks like to the
caller": non-zero exit, a named file, a named value, and a stated reason — not a bare
failure the caller has to re-diagnose.

### 2.4 Structured return shape (for a future caller, or for testing — no bodies)

```
@spec run_autofix(files :: [String.t()]) :: %{
  fixed: [%{path: String.t(), from: String.t(), to: String.t()}],
  refused: [%{path: String.t(), found: String.t(), reason: String.t()}]
}
```
`run/1` calls this internally when `"--autofix"` is present, then re-runs (or reuses) the
existing lint pass over the post-fix file set so H2/H3/H4/H5/H6 and the exit-code logic are
computed exactly as today, against the corrected files. This design does **not** change how
`hard_new`/`hard_grandfathered` are computed for any rule other than H1's autofixable subset
— H2 through H6 are untouched.

### 2.5 Why this is safe against the corpus finding

**Corrected per CODE-DESIGN-VALIDATOR rework-1 MINOR finding.** ORCH's original scan used a
broad glob (`handoffs/**/*.json`) rather than the linter's own discovery pattern
(`handoffs/**/step*.*`, `handoff_files/1` at line 279) and reported a null-status file that
turned out not to exist under the linter's actual discovery — the file it cited is not even
matched by `handoff_files/1`'s basename filter, and the null field it found was the
unrelated `result.status`, not the top-level `status` this design governs. Rescanned with
the linter's own pattern: **1900 files, zero bad, missing, null, or non-string top-level
`status` values.** `--autofix` therefore has nothing to correct in the corpus today, under
either scan. This design is deliberately **not** a migration: it does not run once over
history, does not touch any of the 6 `@grandfathered` entries (none is an H1 entry today —
H1's grandfather list is empty; verified by reading `@grandfathered` above, which lists only
H2/H3 entries), and only ever acts on a *new* violation introduced going forward.
`--autofix` is invoked on the same `handoff_files/1` discovery as today (now reachable via
`--dir`, per §2.1) — no new discovery logic, no historical replay.

**Since null/missing is confirmed absent from the corpus today, but "currently unpopulated"
is not the same claim as "cannot occur," §2.2's mapping table already specifies (and this
section restates so the path is not left implicit just because nothing exercises it today)
that a missing or non-string top-level `status` is in the refuse set, identically to
`"FAIL"`: `--autofix` leaves such a file untouched, still counts it as a hard violation, and
reports it with a reason naming the actual condition found (`"missing"` or the actual
non-string type/value present) rather than reusing the `FAIL`-specific ambiguity wording —
the caller should be told *what was found*, not given a message written for a different
case. This is a defensive specification, not a response to an observed occurrence: `check_h1_status/2`
(verified at lines 411-435) already has a distinct non-string/missing clause today, separate
from its enum-mismatch clause, and `--autofix`'s refuse path is specified to mirror that
same distinction rather than collapsing both into one generic "refused" case.

---

## 3. Mechanism B — ORCH reads the just-received handoff's top-level `status` before its dispatch-time commit, wired into `HANDOFF_PROTOCOL.md` §1.3's existing procedure

### 3.1 Why this is the second mechanism, not a duplicate of A

A lives entirely on the **push/CI** timeline — it can only ever act once a file is pushed,
so on a single local session it gives no earlier feedback than today (ISSUE-FIXER's own
finding: "an agent still won't know until push/CI time under (d) alone, same as today, just
self-heals instead of failing the build"). It also cannot handle `FAIL`. B closes both gaps:
it fires **inline, between steps, before the next dispatch**, and it is the party (ORCH)
that reads rather than writes, so it can flag `FAIL` for a human-equivalent decision instead
of needing to resolve it.

### 3.2 Where, mechanically, in ORCH's existing procedure

`HANDOFF_PROTOCOL.md` §1.3, restated only to the extent needed to anchor the insertion point
(full rule already governs, not re-derived here): ORCH's **dispatch-time commit** is not
"commit the new PENDING handoff" in isolation — every dispatch after Step 00 is preceded by
ORCH having just received the *previous* step's completed handoff. This design adds one
check, positioned as an **inseparable sub-step of that existing, already-mandatory
commit-at-dispatch action**, not a new standalone step ORCH could choose to skip:

```
ORCH's existing procedure (§1.3), annotated — nothing renumbered, one clause inserted:

  1. Receive completed handoff H(n) from the just-finished step.
  2. [INSERTED] Read H(n)'s top-level "status" field. If it is not one of the
     six legal enum values (PENDING/IN_PROGRESS/COMPLETED/FAILED/ESCALATED/
     CANCELLED), STOP — do not write H(n+1) yet. Correct H(n)'s top-level
     status by hand to the value the file's own content supports (its
     result.status, timestamps, and next_action say what actually happened),
     using the same PASS/COMPLETE/DONE -> COMPLETED judgement Mechanism A
     encodes for the safe subset; for a literal "FAIL"/ambiguous value, ORCH
     itself makes the lifecycle-vs-result-shape judgement call (this is
     exactly what already happened by hand for occurrences 5 and 6, per
     anti-patterns.md's own recurrence log -- this design promotes that
     manual act already on record into a required clause of an existing
     mandatory step, not a new invented behavior).
  3. Write H(n+1) as a new PENDING handoff.
  4. Commit H(n+1) (and, if step 2 corrected H(n), the correction to H(n) --
     same commit or an immediately preceding one) -- BEFORE spawning the
     receiving agent for H(n+1).
  5. Spawn the receiving agent.
```

**The load-bearing property, stated at the correct strength (corrected per
CODE-DESIGN-VALIDATOR rework-1 — see §1.2):** step 2 is not a separate call ORCH can forget
to make *in the sense that a validator or gate would block it* — nothing here is
code-enforced. What is true is narrower and still real: step 2 sits **inside** the same
five-step procedural block whose step 4 (the git commit) is a documented MUST with a clean
compliance record since ISS-0196, written as one numbered sequence rather than as a
separately-skippable instruction. That is the same shape §1.3 already uses successfully, and
it is the reason this design expects step 2 to be followed with §1.3's own reliability, not
with CI's structural certainty. This is the literal combination ISSUE-FIXER recommended and
this design adopts it, refined by (a) making the correction procedure explicit (§3.2 step 2)
rather than leaving it as "ORCH decides," and (b) being explicit, per §3.5 below, that this
mechanism's guarantee is procedural, not structural.

### 3.3 Cost, judged against the contended number

Mechanism B's check is **not** a full-corpus lint — it is ORCH reading one field
(`status`) of one JSON file it already has open in its own context (it just received H(n)
as a tool result). This costs zero additional linter invocations and is unaffected by the
74.7s contended full-corpus figure entirely, because it never calls
`mix letflow.lint_handoffs`. This sidesteps the run(_args)-ignores-its-arguments /
no-single-file-mode problem ISSUE-FIXER flagged for candidates (b)/(c) generically: this
design's version of (b) does not need a single-file linter mode at all, because the check is
"is this one string one of six literals," not "run the full schema lint." **No change to
`run/1`'s discovery path is required for Mechanism B.** (Mechanism A's `--autofix` still
runs the full corpus scan, but only at CI/push time, at CI's own existing cadence — never
per-dispatch — so it never pays the per-dispatch multiplication ISSUE-FIXER costed out for
(b)/(c) as generically stated.)

### 3.4 AC5 cost accounting, both mechanisms together

- Mechanism A: zero *new* invocations of `mix letflow.lint_handoffs` — it already runs once
  per CI job, and CI's own timing is not this issue's concern (`letflow.check`'s total
  runtime, dominated by `check.test`, is unaffected by an autofix branch that touches at
  most a handful of string fields). Even under contention (74.7s, ISSUE-FIXER's measured
  outlier), this is CI-side, on GitHub's runner, not on a contended local workstation, so the
  contended-local number does not even apply to it.
- Mechanism B: one string-equality check against a 6-element list, per dispatch, in-memory,
  no subprocess, no `git`/`mix` invocation. Immeasurably cheap against either the 5-9s quiet
  figure or the 74.7s contended figure, because it never invokes the linter at all.

So the design's real answer to AC5 is: **the contended 74.7s figure is a reason not to add a
new full-corpus-linter call site**, and this design adds none — Mechanism A reuses an
existing call site (CI), Mechanism B needs no linter call. A design that instead wired
option (b)/(c) as literally "call `mix letflow.lint_handoffs` at every dispatch" would have
to pay 74.7s × (dispatches per run) under contention, which is exactly why §5.2 rejects that
literal reading of (b)/(c) in favor of the field-read shown above.

### 3.5 Where the actual structural guarantee lives, stated honestly

**Only Mechanism A (§1.1/§2) carries a structural guarantee.** It rides GitHub Actions'
own trigger and a merge precondition neither agent memory nor a skipped instruction can
route around. Mechanism B (§1.2/§3.1-3.4) does not add a second, independent structural
guarantee — it is procedural, inheriting §1.3's track record, which is strong but not
code-enforced. Stated as the consequence the validator asked this design to address
head-on: **if Mechanism B were silently dropped from some future ORCH session — the same
way six prior prose mitigations were — the violation would still be caught, every time,
by Mechanism A at CI**, before merge. Nothing about "structurally impossible to merge"
depends on B.

**So why keep B at all, rather than shipping A alone?** Because B is a real, free latency
win layered on top of an unconditional backstop, not an alternative to one. Under A alone,
every occurrence is caught only at push/CI time — minutes after the mistake, the same
timing every one of the 8 real occurrences already had. Under A+B, the same violation is
caught **inline, between steps, before the very commit that would first put it in git** —
before CI even runs — on the strength of a procedure with a clean record since ISS-0196 and
zero marginal cost (§3.3/§3.4: no linter invocation at all). That is real value even though
it is not a second guarantee.

**ORCH's own framing, evaluated:** "CI-guaranteed plus a procedural early-catch" is adopted
as this design's honest self-description, for the reason ORCH gave — it is a materially
better answer than six prose-only predecessors, specifically *because* the CI half
genuinely cannot be skipped, so the worst case if the procedural half ever lapses is a
return to today's status quo (caught at CI), not a silent miss. What this design does not
do, and what would repeat the overclaiming mistake this rework fixes, is describe that
combination as "structurally impossible to violate" — the correct sentence is "structurally
impossible to **merge** with the violation still present," which is what A alone
guarantees, with B making the common case faster to catch.

---

## 4. Verdict on the four candidate options named in ISS-0440

### (a) Tracked `.githooks/pre-push` — REJECTED as a required mechanism; not part of this design

ISSUE-FIXER proved the mechanism works (live test in an isolated clone, hook fired, blocked
the push). Rejected anyway, for AC2 reasons stated plainly:

- **AC2 is not satisfied by the hook alone.** An unconfigured host (no `core.hooksPath` set)
  gets **zero** protection from it, and nothing today detects that non-setup — ISSUE-FIXER
  confirmed no `check_*` task inspects git config or hook presence, and `check_toolchain`
  (the nearest precedent, verified read this session) checks `.tool-versions` drift, not git
  hook wiring. Building such a check is possible in principle, but ISSUE-FIXER's own honest
  assessment holds: that check could only run inside `mix letflow.check`, i.e. at CI, which
  already independently catches 100% of these violations via Mechanism A/§1.1 regardless of
  hook presence. A "verify hooks are configured" gate would be strictly weaker than and
  fully subsumed by Mechanism A — it would detect the *symptom* (host not configured) using
  the exact same unconditional CI gate that already catches the *disease* (bad value merged)
  without needing to know about hooks at all.
- **Net marginal value.** The hook's only genuine advantage over Mechanism A is feedback
  latency on a *configured* host — failing at `git push` instead of at CI, seconds instead of
  minutes. That is real but small, and it is not free: it needs new tracked infrastructure
  (`.githooks/pre-push`), a documented setup step (`docs/guides/backend_developer_guide.md`),
  and — per this project's own CLAUDE.md instruction — **must not touch `.git/hooks` or
  git config on the shared checkout**, which is exactly the kind of per-host state this
  multi-worktree, multi-session workstation (3 concurrent worktrees confirmed live during
  this very design step) makes error-prone to keep configured everywhere.
- **Verdict:** not included in this design's required mechanism. If a future run wants the
  latency win, it can add the hook as a *pure addition* on top of Mechanisms A+B (the hook
  would just be an earlier, optional trigger of the same `mix letflow.lint_handoffs` check
  Mechanism A already runs at CI) — but AC2 must then be satisfied by pointing at Mechanism
  A's CI gate as the "existing gate that catches the non-setup case," exactly as this design
  already establishes it does independently of any hook. Recorded here so a future reader
  does not silently re-decide this without the AC2 answer already on record.

### (b) ORCH lints before dispatching the next step — ADOPTED, refined (Mechanism B, §3)

Adopted, but **not** as literally "ORCH runs `mix letflow.lint_handoffs`" (too costly per
dispatch under contention, and over-general for what's being checked). Refined to: ORCH
reads one field of a handoff already in hand, as an inseparable clause of the existing,
already-mechanical §1.3 commit-at-dispatch procedure. See §3 for the full reasoning and
exactly why this reading avoids the "prose asking someone to remember" failure mode the
prior six mitigations all shared.

### (c) Lint call in every role's dispatch template — REJECTED, reasoning stated

ISSUE-FIXER's own comparison holds and this design agrees: (c) asks the **completing**
agent — the party demonstrated, in all 8 occurrences, to be the one who makes this exact
mistake — to also catch its own mistake, immediately after making it. (b)/Mechanism B
instead puts the read in a different, independent party (ORCH) with a clean record on this
defect, reading the file fresh rather than trusting its own just-written output. Also:
editing all ~15 role files' spawn prompts is a larger, more error-prone surface than editing
one procedure document (§1.3) once — more places a future edit could silently drop the
instruction. **Not adopted.**

### (d) `--autofix` mode — ADOPTED, restricted (Mechanism A, §2)

Adopted for the closed, empirically-verified-safe subset `{PASS, COMPLETE, DONE} →
COMPLETED` only. Explicitly **not** adopted for `FAIL` or any other value — see §2.2/§2.3
for the refusal contract, which exists specifically because ISSUE-FIXER showed the one
historical `FAIL` instance is unrecoverable from git history (squash-merged away) and
therefore the mapping cannot be verified either way for that value. An autofix that
guessed on `FAIL` would satisfy AC1/AC3-style "catches everything" framing while actually
being the worse failure mode HANDOFF_PROTOCOL.md's Instruction Precedence chain calls out:
*"reporting unverified work as done"* — converting a possibly-genuinely-FAILED handoff into
COMPLETED corrupts the pipeline's own record of what happened, which every gate/escalation
count downstream depends on being accurate.

---

## 5. Acceptance criteria — mapped explicitly

(Read from `docs/issues/ISS-0440.yaml`'s own description; the issue file states the
requirement inline rather than as a numbered `AC` list, so this section names each demand
the description makes and maps it to the concrete design element addressing it, per this
role's own mandate that every acceptance criterion maps to something concrete.)

### AC1 — "make the violation structurally impossible... catch a deliberately-introduced bad status before CI, demonstrated by a real run"

Two catches, of two different strengths (per §3.5 — not restated at length here):

- **Mechanism A** catches (and for the safe subset, self-heals) it **at CI**, as a hard gate
  that already exists and already blocks merge. This is the one that makes "structurally
  impossible to merge with the violation present" literally true, because nothing bypasses
  CI.
- **Mechanism B** catches it **before CI even runs** — at the moment ORCH would otherwise
  commit the very handoff carrying the bad value, per §3.2 step 2 — *when the documented
  §1.3 procedure is followed*, which it reliably has been since ISS-0196 but is not
  code-enforced. B is the earlier catch on the common path, not a second guarantee; if it
  is ever skipped, A still catches the same violation at CI, just later.

**How this is demonstrated, concretely, per the handoff's own self-referential
instruction** ("this run's own handoffs are written by the very agents that produce these
violations... a fix that cannot catch a violation planted in its own run's handoffs has not
been shown to work"), **and corrected per CODE-DESIGN-VALIDATOR rework-1 BLOCKER 2**: the
first draft of this plan placed the fixture *outside* `handoffs/` and expected a bare
`mix letflow.lint_handoffs` invocation to see it — that cannot work, because
`run(_args)` calls `handoff_files()` with no argument and today's hardcoded default is
`@handoffs_dir = "handoffs"` (verified), so anything outside `handoffs/` is invisible to a
real CLI run. §2.1's new `--dir` flag exists specifically to make this demonstration
executable as a **real run with real, quotable output**, using a fixture directory that is
never `handoffs/` itself and is therefore never linted by any other host's CI:

1. Take a **copy** of one of this run's already-completed handoff files (e.g.
   `handoffs/WF03-ISS0440-20260903/step-01-issue-fixer-diagnosis.json`) into a scratch
   fixture directory **outside `handoffs/`** — e.g. `scratch/iss440-fixtures/` (per File
   Placement Rules; never edit the real handoff) or a `test/fixtures/handoffs_lint/`
   directory if TEST-DESIGNER prefers a committed fixture — with top-level `status`
   deliberately set to `"PASS"`.
2. Run `mix letflow.lint_handoffs --dir scratch/iss440-fixtures` (no `--autofix`) — a real
   CLI invocation, now able to see the fixture directory because of §2.1's override —
   demonstrating the planted value is flagged as a new H1 violation, non-zero exit, quoting
   real output. This is the "before CI" catch demonstrated live: the same check CI would
   run, run locally, against a directory CI never even scans, with the bad value visible to
   the CLI for the first time.
3. Run `mix letflow.lint_handoffs --dir scratch/iss440-fixtures --autofix` against the same
   fixture directory — demonstrate the file is rewritten to `"COMPLETED"` in place and the
   run exits 0, quoting real output.
4. Repeat steps 1-3 with `status` set to `"FAIL"` in a second fixture file — demonstrate the
   run still exits non-zero under `--autofix --dir ...`, the file is left untouched, and the
   refusal message names the file, the literal value found, and the stated ambiguity reason
   (§2.3).
5. **Confirm the no-flag/no-`--dir` path is unaffected**, closing the loop on §2.1's
   default-preserving contract: run bare `mix letflow.lint_handoffs` (no flags at all) and
   confirm the scratch fixture directory is **not** scanned (it reports the same file count
   over the real `handoffs/` corpus as before the fixture existed) — proving `--dir`'s
   addition changed nothing about CI's own invocation.
6. This is TEST-DESIGNER/TEST-RUNNER's job (ExUnit tests calling `run/1` with an explicit
   `["--dir", fixture_dir]` args list pointed at a scratch/test fixture directory — no
   production file under `handoffs/` is ever mutated by the test suite), not something
   CODE-DESIGNER runs itself; named here so the acceptance criterion has a stated, concrete,
   *executable* demonstration path rather than "trust the design." If TEST-DESIGNER instead
   prefers a fixture committed **inside** `handoffs/` under a dedicated scratch run-id (e.g.
   `handoffs/_fixtures-iss440/`) rather than using `--dir`, that path carries a hazard this
   design flags rather than endorses: a bad-status file left inside `handoffs/` would be
   linted by **every other host's** `mix letflow.check`, including CI, and would break their
   builds the moment it is committed. `--dir` avoids that hazard entirely by construction
   (the fixture lives outside `handoffs/`, so no other host's default-directory invocation
   ever sees it) and is this design's recommended path for exactly that reason — a
   committed-inside-`handoffs/` fixture is not adopted by this design and is not guaranteed
   safe to commit under any circumstance.

### AC2 — "an unconfigured host must either still be protected, or have its non-setup detected by an existing gate"

Directly satisfied, and the reasoning is why (a)/the hook was rejected rather than adopted
as a required piece: **Mechanism A requires zero per-host configuration.** It rides CI
(§1.1), which runs on GitHub's own runner image regardless of anything any workstation has
or hasn't set up. There is no "setup step" for a host to skip — every host's changes pass
through the identical CI gate before merge, so "unconfigured" is not a state that exists for
this mechanism. **This is the design's actual answer to AC2, not a caveat**: rather than
building a new gate to detect missing hook setup (which ISSUE-FIXER showed would itself only
be able to run inside `mix letflow.check` — i.e., inside the very CI gate that already
catches the underlying defect directly), this design makes the enforcement itself
host-independent, so the detection problem AC2 poses does not arise.

### AC3 — the autofix mapping must not corrupt the pipeline's record

Satisfied by §2.2's closed mapping and §2.3's refusal contract: only the three
verified-unambiguous values are ever rewritten; `FAIL` and everything else is refused, left
untouched, and still reported as a hard violation. No guess is ever made.

### AC4 — the fix must be systemic, not scoped to one role

Satisfied structurally: neither mechanism reads or depends on `to_agent`/`from_agent` at
all. Mechanism A operates on every handoff file regardless of which of the 7 implicated
roles wrote it; Mechanism B is ORCH-side and fires on every dispatch boundary regardless of
which role just completed. This matches ISSUE-FIXER's finding that the 8 occurrences span 7
distinct roles with none responsible for more than 2 — a role-scoped fix (candidate (c),
rejected in §4) could never have covered this distribution; both adopted mechanisms are
role-agnostic by construction.

### AC5 — cost must not change agent behaviour, judged against the contended 74.7s figure

Answered in full in §3.4: no new full-corpus linter call site is added by either mechanism.
Mechanism A reuses CI's existing single invocation; Mechanism B never invokes the linter.
The 74.7s contended figure is the reason this design specifically avoids the literal "lint
at every dispatch" reading of candidate (b)/(c) — that reading is the one this design
rejects in §4(c) and refines away from in §3.3.

---

## 6. Open questions (not silently resolved)

### 6.1 Should `FAIL` ever become autofixable, and under what evidence?

This design leaves `FAIL` permanently in the refuse-set given currently available evidence
(one historical instance, unrecoverable from git history). If a future occurrence of a
top-level `FAIL` value is caught **before** being squashed out of history (i.e., Mechanism B
catches it pre-commit, or a future PR carrying one is inspected before squash-merge), that
would be new, directly-observable evidence about which lifecycle state such a value
"should" resolve to, and could inform a future, separate change to `@autofix_map` in §2.2.
This design does not attempt to guess that answer now, and ELIXIR-DEV must not extend the
map to cover `FAIL` under this handoff's scope — that would silently resolve exactly the
ambiguity this design was told to respect.

### 6.2 Exact wording/placement of the §3.2 procedural insertion in `HANDOFF_PROTOCOL.md`

This design specifies the **content** of the inserted step (§3.2) and states it must live
inside §1.3's existing numbered procedure (not as a new, separately-skippable section) so it
inherits that section's "no size threshold, no judgement gate" **wording** — the same
documented-MUST framing §1.3 already uses, with the same procedural (not code-enforced)
reliability class stated explicitly in §1.2/§3.5, not a stronger claim than §1.3 itself
makes. It does not draft
the exact prose/heading ELIXIR-DEV (or whichever role edits `HANDOFF_PROTOCOL.md` — this is
a docs change, in scope for this fix per the issue's own `affected_files` list) will commit,
since that is implementation of the documentation, not a design-level decision. The one hard
constraint: it must be inserted as a clause of the existing dispatch-commit procedure, never
as a standalone "ORCH should also run a check" bullet elsewhere in the file — the latter is
the exact shape that failed six times already.

### 6.3 Whether Mechanism A's fixed file should also be committed atomically with the CI run that found it

Out of scope: CI (GitHub Actions) cannot commit back to the PR branch as part of a check
run without additional write-back plumbing (a bot commit, a `git push` from within the
Action) that this design does not propose. `--autofix` is specified as a **local-invocable**
Mix task capability (run by a developer/agent locally, or optionally wired into a
`mix letflow.check`-adjacent local workflow) — CI's own invocation of `letflow.check` in
`ci.yml` continues to call the **non-autofix** path (today's `mix letflow.check` is
unchanged; `--autofix` is not part of the `letflow.check` alias in this design, precisely
because CI must keep failing loudly on a bad value, not silently rewrite the PR branch
mid-check-run). This is worth flagging explicitly: **Mechanism A's autofix does not run
inside CI at all** — CI keeps running the plain, non-autofixing lint (§1.1's `letflow.check`
alias is unchanged), which is what makes AC2's answer clean (a host needs no autofix
tooling for CI to still catch the defect). `--autofix` is a convenience for a developer/ORCH
fixing a locally-discovered violation by hand before pushing, not a new CI behaviour. If a
future change wants CI to self-heal and push a fix commit, that is a separate, larger design
decision (write access from a CI job, atomicity with the rest of the check run) and is
explicitly not decided here.

---

## 7. Summary of concrete elements for ELIXIR-DEV

1. `lib/mix/tasks/letflow.lint_handoffs.ex`:
   - `run/1` parses `args` for `"--autofix"` and `"--dir <path>"` (currently ignored
     entirely — becomes read, not ignored), per §2.1. No-flag invocation (CI's own,
     unchanged) must resolve identically to today's hardcoded `@handoffs_dir` default —
     this is the specific property to test, not just narrate.
   - New `@autofix_map` (or equivalently named) closed map, exactly
     `%{"PASS" => "COMPLETED", "COMPLETE" => "COMPLETED", "DONE" => "COMPLETED"}` — `FAIL`
     and missing/non-string values are never keys in this map (§2.2/§2.5).
   - New function (name/shape per §2.4) applying that map file-by-file, producing
     `fixed`/`refused` lists, and rewriting only the `status` field of `fixed` files in
     place (preserve every other field and key order as far as Jason's encoder allows;
     ELIXIR-DEV decides the exact re-serialization approach — not a design-level concern).
   - Output sections per §2.3/§2.5: fixed files reported distinctly from refused files,
     refused files still counted toward the non-zero exit, and a refused file's reported
     reason names the actual condition found (missing vs. `FAIL` vs. other non-enum value)
     rather than one generic message.
   - `letflow.check` alias in `mix.exs` is **unchanged** — still calls plain
     `letflow.lint_handoffs` with no arguments, so no `--autofix` and no `--dir` (§6.3).
2. `docs/agents/shared/HANDOFF_PROTOCOL.md` §1.3: insert the §3.2 clause into the existing
   dispatch-commit procedure (exact prose is ELIXIR-DEV's/DOC-UPDATER's to draft, content
   constraints per §3.2 and §6.2) — worded as a procedural addition to §1.3's existing MUST,
   not as a claim that the insertion is itself code-enforced (§1.2/§3.5).
3. `docs/anti-patterns.md`: per the issue's explicit instruction, do **not** add an eighth
   tally line as the fix. If anything is appended here, it should be a closing note stating
   this occurrence's mitigation combines a structural gate (Mechanism A, at CI — nothing
   bypasses it) with a procedural early-catch (Mechanism B, riding §1.3's track record) —
   described at that precision, not as uniformly "structural" — rather than a ninth
   recurrence entry. DOC-UPDATER's call at Step 6, not this step's.
4. Test fixtures for AC1's demonstration live under `scratch/` or `test/fixtures/` (per File
   Placement Rules), always **outside** `handoffs/`, invoked via the new `--dir` flag
   (§2.1, §5 AC1) — never inside `handoffs/` (hazard: any other host's CI would lint it
   too) and never mutating a real `handoffs/**/*.json` file to prove the mechanism.
