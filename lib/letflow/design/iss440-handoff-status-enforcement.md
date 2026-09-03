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

## 1. The two unavoidable actions this design rides on, and the THREE tiers of guarantee they actually produce

**Corrected per CODE-DESIGN-VALIDATOR rework-2 BLOCKER 1 — read this subsection before any
other, since it sets the vocabulary every later section is now held to.** Rework-1 withdrew
an overclaim about Mechanism B ("no path through the procedure without the check") and
replaced it with a claim about Mechanism A that turned out to be the *same class of error
one level down*: "structurally impossible to merge... because nothing bypasses CI." That is
false, verified independently by both ORCH and CODE-DESIGN-VALIDATOR against this repo's
actual state, not a hypothetical:

- `gh api repos/tvolodi/letflow/branches/main/protection` → `404 "Branch not protected"`.
  `main` has **no branch protection at all** — no required status checks, nothing.
- PR #848, merged by this very run's own session earlier today, has a `statusCheckRollup`
  showing its two "Backend gate (mix letflow.check)" runs as **FAILURE** and **SUCCESS** —
  it was merged with a failing gate present. ORCH re-confirmed this directly; it is a live
  counterexample in this repo's own history, not a hypothetical risk.

**So the correct statement is not two tiers ("structural" vs. "procedural"), it is THREE,**
and this design uses exactly these three, by name, everywhere below:

- **Tier 1 — CI RUNS, unconditionally. Structural, verified.** `.github/workflows/ci.yml`'s
  `backend` job's only content step is `run: mix letflow.check` (no `if:`, no
  `continue-on-error:`, verified at the file's own line). `mix.exs`'s `letflow.check` alias
  (lines 91-108, verified read this session) is a fixed, non-optional Mix list including
  `letflow.lint_handoffs` already, unconditionally, today. GitHub Actions runs this job on
  every `push`/`pull_request` event by workflow trigger, not by an agent choosing to invoke
  it, and Mix does not skip an alias entry because an agent forgot to ask for it. **Nothing
  about whether this tier fires depends on any agent's memory or judgement.**
- **Tier 2 — a violation is therefore always DETECTED and RECORDED. Structural, verified.**
  Tier 1 firing unconditionally means `mix letflow.lint_handoffs`'s H1 check always runs
  against every push, and its non-zero exit and violation report are always produced and
  always visible in the CI run's own log — this follows mechanically from Tier 1 and adds
  no further assumption. **This is the load-bearing guarantee this design actually
  delivers: detection cannot be skipped.**
- **Tier 3 — whether that detection BLOCKS THE MERGE. Procedural, NOT structural, and
  demonstrably violated in this repo's own history (PR #848, above).** Detection stopping a
  merge requires either GitHub-enforced branch protection (absent — the 404 above) or the
  merging agent choosing to honor a red result (`GIT_MERGE.md`'s CI-green gate is a written
  MUST, the same character of guarantee as the §1.3 claim rework-1 already corrected — a
  documented procedure a human-equivalent agent is expected to follow, not something GitHub
  enforces server-side on this repository as currently configured).

```
letflow.check_toolchain
letflow.check_requirements_registration
letflow.check_deferral_staleness
letflow.lint_handoffs          <- already here, unconditionally, today (Tier 1)
format --check-formatted
compile --warnings-as-errors
letflow.check.test
```

**What ISS-0440's own title asks for ("make the violation structurally impossible") is
therefore NOT fully achievable in this repo's current configuration, and this design says
so plainly rather than leaving the title silently unmet.** What this design achieves is
Tier 1 + Tier 2 at full strength (unconditional detection, no agent decision involved) plus
two procedural enforcement points (Mechanism B's early catch, §3; Tier 3's existing
CI-green-gate MUST). What would close the gap to true Tier-3 structural enforcement is
**branch protection on `main` with `mix letflow.check`'s job set as a required status
check** — a one-time GitHub repository administration action, not a code change this design
can specify, and explicitly out of scope for this fix (see §6.4, new). ORCH is filing that
as its own follow-up issue; this design references it as a known, named gap rather than
implying Tier 1+2 alone already closes it.

This is why §2's autofix change rides Tier 1/2 and nowhere else: it does not need a new call
site. `mix letflow.lint_handoffs` already executes on this path today; the only change is
what it does with a bad value it finds, and only for the closed, verified-safe subset. Read
"unavoidable action #1" in this design's later sections as shorthand for "Tier 1/2 fires
unconditionally" — never as a claim that Tier 3 (merge blocking) is unconditional, which it
is not.

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
for exactly where in that existing procedure the read is inserted, and §3.5 (corrected at
rework-2 — see §1's three-tier framing) for the consequence of B being procedural rather
than structural: it does not, on its own, deliver Tier 1/2's unconditional-detection
guarantee — that is Mechanism A's alone (§1.1) — and B's honest role is an early-catch
latency improvement layered on top of it, not a second independent guarantee, and neither
mechanism reaches Tier 3 (§1, §6.4).

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

### 2.1a `--dir`'s own misuse surface, guarded — NEW, per CODE-DESIGN-VALIDATOR rework-2 BLOCKER 2

§2.1 above is unchanged (settled at rework-1). This subsection adds the two guards
rework-2 requires; it does not alter `resolve_dir/1`'s default-preserving contract in any
way.

**(a) A scoped run must never be visually indistinguishable from a genuine clean full-corpus
run.** `--dir some/empty/or/wrong/dir` would otherwise report "0 violations, exit 0" —
identical in shape to the real output of a clean 1900-file corpus scan (§2.5). An agent (or
a human) reading only the exit code, or a truncated log tail, could mistake a
near-vacuous scoped run for a verified-clean full corpus. This design adopts **both**
guards named in the rework dispatch, not one — they address different failure points:

- **A hard guard on zero discovered files.** When `handoff_files(dir)` returns `[]` for a
  directory that does not equal `@handoffs_dir`'s resolved value, `run/1` treats this as a
  usage error, not a clean result:
  ```
  @spec guard_empty_scope(dir :: String.t(), files :: [String.t()]) :: :ok | no_return()
  # files == [] and dir was explicitly supplied via --dir -> Mix.raise/1 naming the
  # directory and stating "0 files discovered -- refusing to report success for an
  # empty or non-existent scan target"; non-zero exit.
  # files == [] and dir is the DEFAULT (@handoffs_dir, i.e. no --dir given at all) is
  # NOT this case -- an empty real handoffs/ directory would be a genuinely different,
  # pre-existing anomaly (see note below), not a --dir misuse symptom, so the guard
  # applies only when --dir was explicitly passed.
  ```
  This closes the *worst* misreading (an empty/mistyped scope silently reporting success)
  outright, at the cost of exit code alone.
- **An unmissable banner naming the scanned directory and file count, on every run,
  including a healthy one.** Independent of (and in addition to) the empty-scope guard,
  because a *non-empty but wrong* `--dir` (e.g. a stale or partial fixture directory that
  happens to contain a few files) would pass the empty-scope guard while still not being
  the real corpus. `run/1`'s existing summary line (today: `"letflow.lint_handoffs: OK --
  0 new violations across #{length(files)} handoff files..."` at line 267) already carries
  a file count — this design requires it to **also** name the directory scanned, on every
  invocation, e.g. prefixed `"[scope: #{dir}]"` or folded into the existing sentence
  (`"...across #{length(files)} handoff files under #{dir}..."` — exact wording is
  ELIXIR-DEV's to pick, the requirement is that the directory string appears in the one
  line most likely to be read even from a truncated log). This banner is unconditional —
  present on the default no-`--dir` path too — so a reader never has to infer scope from
  absence of a flag; it is always stated.

  **Why both, not one alone (justifying the choice per the rework dispatch's own
  instruction):** the empty-scope guard alone would let a *non-empty but still-wrong*
  directory pass silently with a misleading "OK" — the exact ambiguity AC1's own
  demonstration risks if read carelessly (a reader skimming step 5's "no scan of the
  fixture directory" confirmation must be able to tell which directory was actually
  scanned from the output alone). The banner alone would let a genuinely empty/mistyped
  `--dir` still exit 0, which is the specific "green but meaningless" hazard named in the
  rework dispatch. Together, a `--dir` misuse either hard-fails (empty case) or is legible
  in the output (non-empty-but-wrong case) — no combination of the two hazards passes
  unlabelled.

**(b) `--autofix --dir <the real corpus>` is a real, if currently inert, mass-rewrite
surface — stated plainly, not left implicit.** Passing `--autofix` together with `--dir
handoffs` (or simply omitting `--dir`, since `--autofix` alone still resolves to
`@handoffs_dir` per §2.1's parsing) runs Mechanism A's corrective rewrite over the entire
real handoff corpus, not a fixture. This design does **not** restrict `--autofix` to
non-default directories — restricting it would silently reintroduce exactly the
"agent must remember to use the safe flag combination" failure mode this whole design
exists to eliminate (§0), and would also block the legitimate use case of an
ORCH/developer running `mix letflow.lint_handoffs --autofix` locally against the real
corpus to fix a **just-discovered** violation before pushing, which is a real, intended
use of Mechanism A (§6.3). What makes this safe rather than merely unrestricted:

  - The map is closed and safe by construction (§2.2/§2.5): only `{PASS, COMPLETE, DONE}`
    are ever rewritten, only ever to `COMPLETED`, and only the `status` field is touched —
    there is no broader "rewrite anything matching a pattern" surface here to misuse.
  - Every fixed file is reported by path and by old→new value (§2.3) — an `--autofix` run
    against the real corpus is not silent even when it does act; the caller sees exactly
    what changed.
  - **Today, against the real corpus, it is a verified no-op**: 1900 files, zero bad
    values (§2.5) — stated explicitly as a fact about today's corpus state, not a safety
    property of the flag, per the rework dispatch's own instruction not to conflate the
    two. A future run where a bad value genuinely exists in `handoffs/` would see
    `--autofix` correct the safe subset and refuse the rest (§2.3), exactly as designed —
    which is the intended behaviour, not a hazard to be restricted away.
  - This is a lower-stakes surface than it may first appear precisely *because* of the
    grandfathering discipline `lint_handoffs.ex` already applies elsewhere (§2.5): no
    historical file is silently touched by anything in this design — autofix only ever
    acts on a file whose top-level `status` is presently in the unsafe/closed set, which
    the corpus scan shows is currently empty.

  **Note on the "default `--dir` with zero files" carve-out above:** if a future
  `handoffs/` directory were ever legitimately empty (e.g. a fresh checkout before any run
  has occurred), that is a pre-existing edge case of `handoff_files/1`'s own default
  behaviour, not one this design's `--dir` flag introduces — out of scope for this fix,
  named here only so the guard's carve-out is not mistaken for an oversight.

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

### 3.5 Where the actual guarantee lives, at the correct tier — stated honestly, rework-2 correction

**Corrected again per CODE-DESIGN-VALIDATOR rework-2 BLOCKER 1.** Rework-1's version of
this section said Mechanism A guarantees the violation "would still be caught, every time,
... before merge" and that "structurally impossible to merge" was literally true. That
conflated Tier 2 (detection) with Tier 3 (merge-blocking) — §1's rewrite is the source of
truth for the distinction; this section restates only what follows from it for Mechanism A
vs. Mechanism B specifically.

**Mechanism A (§1.1/§2) delivers Tier 1 + Tier 2 at full, unconditional strength: the
violation is always DETECTED and RECORDED in CI output.** That part of the original claim —
"nothing bypasses CI" — is true and re-verified (`ci.yml`'s step has no `if:`/
`continue-on-error:`). What is **not** true, and is withdrawn here, is that detection
implies the violation "cannot reach `main`": `main` has no branch protection (verified,
§1), and PR #848 — this run's own — merged today with a FAILURE conclusion present in its
rollup. **Mechanism A's honest guarantee is "always detected and recorded," not "cannot
reach main."** Whether a detected violation actually blocks a given merge is Tier 3,
procedural: it depends on the merging agent honoring `GIT_MERGE.md`'s CI-green-gate MUST,
which is the same character of guarantee as the §1.3 claim rework-1 already corrected for
Mechanism B — a written procedure, not a GitHub-enforced server-side rule, given this
repo's current configuration.

**Mechanism B (§1.2/§3.1-3.4) does not add a second, independent Tier-1/2-strength
guarantee either** — it is procedural throughout, inheriting §1.3's track record (strong,
not code-enforced). Stated as the consequence both blockers together require: **if
Mechanism B were silently dropped from some future ORCH session — the same way six prior
prose mitigations were — Tier 2 still holds: the violation is still detected and recorded
by Mechanism A at CI**, exactly as before. What is *not* guaranteed, with or without B, is
that detection alone stops the merge — that is Tier 3, and it is the same gap regardless of
which mechanism did the detecting.

**So, stated at the precision both rework rounds have now converged on:** this design
delivers unconditional detection (Tier 1+2, via Mechanism A) plus two procedural
enforcement points (Mechanism B's early, pre-CI catch at the dispatch boundary, and the
pre-existing CI-green-gate MUST that is supposed to act on Tier 2's output at Tier 3). It
does **not** deliver a code-enforced guarantee that a detected violation is blocked from
`main` — that gap is real, it is named explicitly (§1, §6.4), and closing it requires repo
administration this design does not perform.

**Why this combination is still worth having, even though ISS-0440's literal title is not
fully met.** Every one of the 6 prior prose mitigations produced **no reliable detection at
all** — each depended on some agent remembering to look. This design's Tier 1+2 is
detection that cannot be skipped, which is a categorically different — and strictly
stronger — property than anything tried before, even though it stops short of Tier 3.
Under A alone, every occurrence is caught at push/CI time, with the result visible in CI
output even if a merge proceeds past it (as PR #848 shows can happen). Under A+B, the same
violation is additionally caught **inline, between steps, before the very commit that would
first put it in git** — before CI even runs — at zero marginal linter cost (§3.3/§3.4). That
is real, useful value on the common path; it is not, and is no longer described as, a
second independent guarantee, and it does nothing for Tier 3 either.

**ORCH's own framing, evaluated at the corrected precision:** "unconditional detection plus
two procedural enforcement points" is adopted as this design's honest self-description —
materially better than six prose-only predecessors that produced no detection at all, but
explicitly **not** "structurally impossible to violate" and **not** "structurally
impossible to merge." The correct sentence is: *a violation is always detected and recorded
by CI; whether it is then blocked from merging depends on a procedure (`GIT_MERGE.md`'s
CI-green gate) that this repository does not currently enforce server-side.*

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

**Corrected per CODE-DESIGN-VALIDATOR rework-2 BLOCKER 1 — this heading's own premise
("structurally impossible") is answered at the tier precision §1/§3.5 establish, not
asserted at face value.** True structural (Tier 3, merge-blocking) enforcement is NOT
achieved by this design in this repo's current configuration — `main` has no branch
protection (verified, §1) and a red CI run has demonstrably merged before (PR #848). What
*is* achieved, at full unconditional strength, is Tier 1+2: detection. Two catches, both
real, neither claiming more than its tier supports:

- **Mechanism A** catches (and for the safe subset, self-heals) it **at CI** — Tier 1+2,
  unconditional: the check always runs and a violation is always detected and recorded in
  CI's output. This does **not** mean the violation is blocked from `main` — that is Tier 3,
  which depends on the merging agent honoring `GIT_MERGE.md`'s CI-green gate, a written
  procedure this repository does not enforce server-side (§1).
- **Mechanism B** catches it **before CI even runs** — at the moment ORCH would otherwise
  commit the very handoff carrying the bad value, per §3.2 step 2 — *when the documented
  §1.3 procedure is followed*, which it reliably has been since ISS-0196 but is not
  code-enforced (procedural, same tier-3-adjacent character as the CI-green gate itself). B
  is the earlier catch on the common path, not a second guarantee; if it is ever skipped,
  Tier 1+2 still holds — A still detects and records the same violation at CI, just later,
  and whether that then blocks the merge is Tier 3 either way.

So AC1's "catch... before CI" clause is satisfied by Mechanism B (procedurally reliable,
not code-guaranteed) and its "demonstrated by a real run" clause is satisfied by the
steps below; AC1's implicit premise that this makes the violation *structurally impossible
to merge* is not fully met, and this design says so explicitly rather than implying
otherwise — see §1's closing paragraph for the named, out-of-scope gap (branch protection)
that would close it.

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

Directly satisfied **at the Tier 1+2 (detection) strength §1/§3.5 establish** — AC2's own
wording asks for detection ("have its non-setup detected"), not merge-blocking, so this
criterion does not run into the Tier 3 gap named there. The reasoning is also why (a)/the
hook was rejected rather than adopted as a required piece: **Mechanism A requires zero
per-host configuration.** It rides CI (§1.1), which runs on GitHub's own runner image
regardless of anything any workstation has or hasn't set up. There is no "setup step" for a
host to skip — every host's changes are scanned by the identical CI gate, unconditionally
(Tier 1), so "unconfigured" is not a state that exists for this mechanism's *detection*
property. **This is the design's actual answer to AC2, not a caveat**: rather than
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

### 6.4 The Tier 3 gap — branch protection — is a NAMED, out-of-scope repo-administration follow-up, not silently left unaddressed

**New, per CODE-DESIGN-VALIDATOR rework-2 BLOCKER 1.** §1/§3.5/AC1 establish that this
design achieves Tier 1+2 (unconditional detection) but not Tier 3 (a detected violation
provably cannot merge), because `main` carries no branch protection today (`404` on
`repos/tvolodi/letflow/branches/main/protection`) and PR #848 shows a red run merging in
practice. Closing that gap requires **GitHub branch protection on `main` with
`mix letflow.check`'s "Backend gate" job (and, if desired, "Frontend gate") configured as a
required status check** — a repository-settings action taken through GitHub's API or web
UI, not a code or documentation change any of this design's two mechanisms can specify or
implement. This is explicitly **out of scope for this design and for ELIXIR-DEV's
implementation of it** — no `.ex`, `.md`, or `.yml` change proposed here performs it. ORCH
is filing this as its own follow-up issue (per `docs/agents/protocols/ISSUE_QUEUE.md`); this
design records the gap by name, with the exact verification command that demonstrates it
today (`gh api repos/tvolodi/letflow/branches/main/protection`), so a future reader finds a
named, tracked gap rather than an implication that Tier 1+2 alone already closed it.

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
   - **New, §2.1a:** a hard guard refusing (`Mix.raise/1`, non-zero exit) an explicitly
     `--dir`-supplied directory that discovers zero files, and an unconditional summary
     banner naming the scanned directory (in addition to the existing file count) on
     every run, default path included — both guard against a scoped `--dir` run being
     mistaken for a genuine clean full-corpus result.
2. `docs/agents/shared/HANDOFF_PROTOCOL.md` §1.3: insert the §3.2 clause into the existing
   dispatch-commit procedure (exact prose is ELIXIR-DEV's/DOC-UPDATER's to draft, content
   constraints per §3.2 and §6.2) — worded as a procedural addition to §1.3's existing MUST,
   not as a claim that the insertion is itself code-enforced (§1.2/§3.5).
3. `docs/anti-patterns.md`: per the issue's explicit instruction, do **not** add an eighth
   tally line as the fix. If anything is appended here, it should be a closing note stating
   this occurrence's mitigation delivers unconditional detection (Tier 1+2, Mechanism A at
   CI — the check itself always runs and always records a violation) plus two procedural
   enforcement points (Mechanism B's early catch, and the pre-existing CI-green-gate MUST
   that Tier 3/merge-blocking still depends on, since `main` carries no branch protection
   today) — described at that three-tier precision, never as uniformly "structural" or as
   "cannot reach main" — rather than a ninth recurrence entry. DOC-UPDATER's call at
   Step 6, not this step's.
4. Test fixtures for AC1's demonstration live under `scratch/` or `test/fixtures/` (per File
   Placement Rules), always **outside** `handoffs/`, invoked via the new `--dir` flag
   (§2.1, §5 AC1) — never inside `handoffs/` (hazard: any other host's CI would lint it
   too) and never mutating a real `handoffs/**/*.json` file to prove the mechanism.
5. **New — out of scope for this implementation, but tracked (§6.4):** GitHub branch
   protection on `main` with `mix letflow.check`'s job(s) as required status checks is the
   action that would close the Tier 3 gap (a detected violation provably cannot merge).
   ELIXIR-DEV does not perform this — it is repo administration, filed by ORCH as its own
   follow-up issue, referenced here so it is not silently left unaddressed.
