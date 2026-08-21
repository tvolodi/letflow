# REQ-114 — Wire `scripts/test_parallel.sh` into workflow/role docs

**Type:** docs-only edit plan (no `lib/letflow/` module, no Ecto schema, no gen_statem
state — this stands in for the usual module design per CODE-DESIGNER's brief for this
requirement). Produced by CODE-DESIGNER, to be executed verbatim by DOC-UPDATER at
WF-02 Step 2a (per `docs/migration/decisions/0008-*.md`'s Option A pick: DOC-UPDATER
owns this edit). CODE-DESIGNER does **not** apply these edits itself.

**Source of interface facts:** `scripts/test_parallel.sh`'s own header comment
(read in full for this design). Key facts restated here because they drive the exact
prose each edit site needs:

- Usage: `scripts/test_parallel.sh [args passed through to every partition's mix test
  invocation]` — a drop-in replacement for a bare `mix test [args]` invocation.
- Partition count `N`: `$TEST_PARALLEL_N` env override if set and a positive integer,
  else `nproc`, else `getconf _NPROCESSORS_ONLN`, else hard-fail. Never a hardcoded
  fallback number.
- Pre-compiles `MIX_ENV=test mix compile` exactly once before any partition launches.
- Runs N background `MIX_TEST_PARTITION=<i> mix test --partitions N --no-color "$@"`
  processes, waits on each individually, parses each partition's `Result:`/`Failed:`
  ExUnit summary lines, and sums properties/tests/failures into one combined total.
- Exit code: 0 only if every partition has a `Result:` line and 0 parsed failures
  (**parsed count is authoritative, not the raw per-partition process exit code** —
  exit 2 per partition is the normal "had ExUnit failures" code on this toolchain, not
  a crash signal).

Every edit site below either (a) swaps the literal `mix test` invocation for
`scripts/test_parallel.sh`, or (b) updates surrounding prose that described plain
`mix test` behavior (e.g. "the entire suite" framing, or assuming a single exit-code
check) so it instead describes: partition-count derivation, and aggregated
pass/fail reporting — per AC1's explicit requirement not to leave stale prose.

---

## File 1 — `docs/agents/workflows/WF-02_requirement_implementation.md`

### Site 1.1 — Step 4 (TEST-RUNNER), lines 351-357 (current text, re-verified this session)

OLD:
```
1. mix test — full suite, not just the new tests (Unblock-Everything: a pre-existing
   failure masking your results must be fixed too, unless it's unrelated and gets
   forwarded per ISSUE_QUEUE.md).
2. If no local toolchain: use the Docker fallback documented in docs/anti-patterns.md.
   Report explicitly if neither is available — do not report PASS without having run
   it (No Speculation).
3. Write test/reports/report-<date>-<run-id>.yaml with the actual output.
```

NEW:
```
1. scripts/test_parallel.sh — full suite, not just the new tests (Unblock-Everything: a
   pre-existing failure masking your results must be fixed too, unless it's unrelated
   and gets forwarded per ISSUE_QUEUE.md). This runs the suite as N parallel
   `mix test --partitions N` processes (N from $TEST_PARALLEL_N if set, else
   nproc/getconf _NPROCESSORS_ONLN) and aggregates every partition's real ExUnit
   Result:/Failed: counts into one combined pass/fail total — exit 0 only if every
   partition's *parsed* count shows 0 failures (the parsed count is authoritative, not
   each partition's raw process exit code; exit 2 per partition is normal for "had
   failures" on this toolchain, not a crash).
2. If no local toolchain: use the Docker fallback documented in docs/anti-patterns.md.
   Report explicitly if neither is available — do not report PASS without having run
   it (No Speculation).
3. Write test/reports/report-<date>-<run-id>.yaml with the actual output, including the
   derived partition count N, its source (env override/nproc/getconf), and the combined
   pass/fail totals scripts/test_parallel.sh printed.
```

### Site 1.2 — Step 5 (RELEASE-VALIDATOR), line 402 (current text)

The requirement text's "line ~372/402" cites two candidate line numbers; re-verified
this session — the actual literal `mix test` invocation in current WF-02 text occurs
**only once**, at line 402. There is no second literal invocation near line 372 (that
region is the "Failure Attribution" shared block, which names no test command). CODE-
DESIGNER's finding: treat this as **one edit site**, not two; DOC-UPDATER should
re-grep before editing in case line numbers drifted between this design and Step 2a.

OLD:
```
1. Independently re-run: mix test (do not trust TEST-RUNNER's report alone — see
   core-directives.md's "Every producing step has a validating step").
```

NEW:
```
1. Independently re-run: scripts/test_parallel.sh (do not trust TEST-RUNNER's report
   alone — see core-directives.md's "Every producing step has a validating step"). Same
   mechanism as Step 4: N parallel `mix test --partitions N` processes, aggregated
   Result:/Failed: counts, parsed-count-authoritative exit code — see
   scripts/test_parallel.sh's header comment for the full contract.
```

---

## File 2 — `docs/agents/workflows/WF-04_full_test_run.md`

### Site 2.1 — Overview ASCII diagram, lines 19-22

OLD:
```
┌───────────────────────┐
│  STEP 1: FULL SUITE   │ ← TEST-RUNNER
│  mix test, whole repo │
└──────────┬─────────────┘
```

NEW (text content only — DOC-UPDATER must re-pad box-drawing characters so the box
stays visually rectangular/aligned with its neighbors; exact character count is a
formatting detail, not a content decision, so it is not pinned here):
```
┌───────────────────────┐
│  STEP 1: FULL SUITE   │ ← TEST-RUNNER
│ test_parallel.sh, all │
└──────────┬─────────────┘
```
Content requirement: the second line must name `test_parallel.sh` (or
`scripts/test_parallel.sh` if width allows) in place of `mix test`; "whole repo" /
"all [parts]" framing may be kept or lightly reworded but must not imply a single
sequential `mix test` run.

### Site 2.2 — Step 1 (TEST-RUNNER), line 49

OLD:
```
1. mix test — the entire suite, not scoped to any one requirement.
```

NEW:
```
1. scripts/test_parallel.sh — the entire suite, not scoped to any one requirement, run
   as N parallel `mix test --partitions N` processes (N from $TEST_PARALLEL_N env
   override, else nproc/getconf _NPROCESSORS_ONLN) with each partition's real
   Result:/Failed: counts aggregated into one combined pass/fail total
   (parsed-count-authoritative, not raw per-partition exit code).
```

### Site 2.3 — Step 1, line 53 (report content line) — no literal `mix test`, but touch for consistency

Current text: `3. Write test/reports/report-<date>-WF04.yaml with full actual output —
pass/fail counts, any StreamData property test seeds used, wall-clock duration.`

This line names no command, so it is not a mandatory edit site under AC1's "literal
invocation" trigger. Recommended (not required) addition for consistency with Site
1.1's report-content update: append ", plus the derived partition count N and its
source" to the existing sentence. DOC-UPDATER's call whether to include it — not
scored against AC1 either way since no literal `mix test` reference is being replaced
here.

### Site 2.4 — Step 2 (RELEASE-VALIDATOR) — explicit decision on the open question

**Requirement's open question:** does WF-04 Step 2's RELEASE-VALIDATOR prose need to
gain an explicit `scripts/test_parallel.sh` reference, or does its current phrasing
already cover the replacement implicitly?

**Re-read of current text (lines 90-104):** none of Step 2's five numbered items name
`mix test` or any other test-invocation command. Item 2 says "independently re-check
its acceptance_criteria against the actual current code/tests" — deliberately
mechanism-agnostic; it never claimed a specific command in the first place, so there is
no stale "plain `mix test`" prose here for AC1 to require replacing.

**Decision: leave WF-04 Step 2 as-is. No edit.** Rationale: AC1 requires replacing
*literal full-suite `mix test` invocations* and updating prose that describes *stale
`mix test` behavior* — neither condition is met here, since Step 2 never invoked or
described a specific test-running mechanism. Naming `scripts/test_parallel.sh`
explicitly in Step 2 would not be wrong, but it would be scope-expansion beyond what
this requirement's acceptance criteria ask for (Step 2's re-verification method is a
separate design question — e.g. whether RELEASE-VALIDATOR should itself invoke
`scripts/test_parallel.sh` when re-checking acceptance criteria — and is explicitly
**not** decided by this requirement; if a future run wants RELEASE-VALIDATOR to name
its own invocation mechanism explicitly, that is a new/amended requirement, not an
implicit reading of REQ-114's acceptance criteria).

---

## File 3 — `.claude/agents/test-runner.md`

Confirmed present (re-grepped this session): two literal `mix test` invocations,
matching ORCH's spot-check.

### Site 3.1 — line 30 ("Core rule — no speculation" section, lines 27-33)

OLD:
```
Never report "tests should pass" or "this looks correct." Run
`mix test` and quote the actual output. If you cannot run it — no
Elixir toolchain in this environment, or `mix deps.get` has no network
access (a known limitation, see `README.md`'s Notes section) — say
that explicitly instead of guessing at the result.
```

NEW:
```
Never report "tests should pass" or "this looks correct." Run
`scripts/test_parallel.sh` and quote the actual output (combined pass/fail totals
across all partitions, not one partition's log). If you cannot run it — no
Elixir toolchain in this environment, or `mix deps.get` has no network
access (a known limitation, see `README.md`'s Notes section) — say
that explicitly instead of guessing at the result.
```

### Site 3.2 — line 43 ("Procedure" step 2)

OLD:
```
2. `mix test` (the `test` alias in `mix.exs` runs `ecto.create` and
   `ecto.migrate --quiet` first automatically).
```

NEW:
```
2. `scripts/test_parallel.sh` (runs the suite as N parallel
   `mix test --partitions N` processes and aggregates each partition's real
   Result:/Failed: counts into one combined total; N derives from $TEST_PARALLEL_N if
   set, else nproc/getconf. The `test` alias in `mix.exs` that each partition's
   `mix test` invocation runs still performs `ecto.create`/`ecto.migrate --quiet`
   automatically, so no separate DB-setup step is needed here — each partition process
   does this independently against the same test DB).
```

### Site 3.3 — line 3, YAML frontmatter `description:` field — explicit non-edit

Current: `description: Runs mix test, diagnoses failures, and reports pass/fail with
real output. ...`

**Decision: leave as-is, not an edit site.** This is a role-selection description
string (consumed by `ListAgents`/agent-roster tooling), not an instruction the agent
executes — it names `mix test` descriptively/generically (the underlying toolchain the
agent ultimately exercises, still true — `scripts/test_parallel.sh` itself shells out
to `mix test --partitions N`), not as a literal full-suite invocation the agent is told
to run verbatim. Changing it is optional polish, not required by AC1's "literal
invocation" trigger; flagged here explicitly per this design's own "no silent
resolution" rule rather than left unaddressed. DOC-UPDATER may update it for polish but
it does not block AC4's "fresh read shows no remaining plain `mix test` reference **for
a full-suite run in a step this requirement was scoped to change**" — the frontmatter
description is not a step.

---

## File 4 — `.claude/agents/release-validator.md`

Confirmed present (re-grepped this session): one literal `mix test` invocation.

### Site 4.1 — line 29

OLD:
```
This role exists specifically because, under humanless operation, nobody else
double-checks that "done" actually means done. Do not read TEST-RUNNER's
`test/reports/*.yaml` and echo its verdict — **re-run `mix test` yourself** and compare.
```

NEW:
```
This role exists specifically because, under humanless operation, nobody else
double-checks that "done" actually means done. Do not read TEST-RUNNER's
`test/reports/*.yaml` and echo its verdict — **re-run `scripts/test_parallel.sh`
yourself** and compare (same aggregated-partition mechanism TEST-RUNNER used — see
`scripts/test_parallel.sh`'s header comment if unfamiliar).
```

No other literal `mix test` invocation exists in this file (confirmed by re-grep this
session — the only other test-related content is the general "What you do" prose,
which already speaks generically of "re-run `mix test`" only at this one site).

---

## Finding — WF-03_issue_resolving.md needs no direct edit (AC2)

**Re-verified this session by reading the file's actual current text**, not assumed:
WF-03's "Steps 2-4" section (lines 96-104) reads: *"Follow the same procedures as
WF-02's Step 1/1b (design), 2a-2d (implement + gates), 3/3b/4 (test)..."* — it never
restates a `mix test` (or any test-command) invocation of its own; TEST-RUNNER's step
inside WF-03 is entirely by reference to WF-02 Step 4. Grep confirms: `grep -n "mix
test" docs/agents/workflows/WF-03_issue_resolving.md` returns **zero matches**.

**Conclusion: no edit needed in WF-03.** Once WF-02 Step 4 (Site 1.1 above) is updated,
WF-03's by-reference mirror automatically picks up the new mechanism with no separate
edit — the requirement's own note is confirmed correct, not merely assumed.

---

## Grep confirmation — no other `.claude/agents/*.md` file has a literal full-suite `mix test` invocation (AC3)

Command run this session:
```
grep -rn "mix test" .claude/agents/*.md
```
Result: four matches total, in three files:
- `.claude/agents/release-validator.md:29` — Site 4.1 above.
- `.claude/agents/test-runner.md:3,30,43` — Sites 3.1-3.3 above.
- `.claude/agents/orchestrator.md:77` — **not a full-suite step invocation.** Full
  line: *"Never report something as working without having run it. If you can't run
  `mix test` or `mix compile` (no toolchain / no network), say so explicitly instead of
  guessing..."* — this is ORCH's generic "no speculation" capability note (ORCH does
  not itself execute a full-suite test-run step in any workflow; it delegates that to
  TEST-RUNNER/RELEASE-VALIDATOR, whose own files are Sites 3/4 above). It is not one of
  the "literal `mix test` full-suite invocations" the requirement scoped in, and the
  requirement's explicit instruction is: "Do not change any TEST-RUNNER/
  RELEASE-VALIDATOR role-file text... unless one of them also hardcodes a literal `mix
  test` invocation" — orchestrator.md is neither role file. **Decision: leave
  orchestrator.md unedited.** Flagged explicitly here rather than silently
  skipped, per this design's "no silent resolution" requirement.

No other `.claude/agents/*.md` file contains the string "mix test" (confirmed by the
grep above returning exactly these four lines across exactly these three files).

---

## Cross-check against acceptance criteria

1. Every literal `mix test` full-suite invocation in WF-02 and WF-04 replaced, with
   surrounding prose updated (partition-count source, aggregated reporting) — Sites
   1.1, 1.2, 2.1, 2.2 above.
2. WF-03 explicitly confirmed (re-read, grepped) to need no edit — see Finding above.
3. `.claude/agents/test-runner.md` and `.claude/agents/release-validator.md` checked
   independently and updated — Sites 3.1, 3.2, 4.1 above; Site 3.3 explicitly
   addressed as an optional non-edit.
4. Post-edit fresh-read check: DOC-UPDATER must, after applying all edits above,
   re-grep `mix test` across the four files and confirm every remaining hit (if any)
   is inside prose that is *not* a full-suite-run step this requirement was scoped to
   change (e.g. a reference to the underlying `mix test --partitions N` mechanism
   `scripts/test_parallel.sh` itself shells out to, which is expected to remain — the
   requirement replaces the *invocation surface*, not every mention of the word
   "mix test" describing what happens underneath).

## Open questions

None left unresolved for DOC-UPDATER to guess at. The two open questions the
requirement named (WF-03's status, and WF-04 Step 2's phrasing) are both decided above
with stated evidence/rationale, per `docs/migration/decisions/0008-*.md`'s framing that
REVIEWER confirms or overrides these at Step 2d — DOC-UPDATER should apply the edits
above as written; if REVIEWER later overrides either decision, that is a decision-record
amendment, not a rework of this design.
