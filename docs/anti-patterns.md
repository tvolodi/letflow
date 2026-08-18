# Anti-patterns — Letflow

Known mistakes and their correct alternative, logged as they're found.
Read this before doing anything non-trivial (see `CLAUDE.md`). Empty
sections are expected early on — this grows with the project.

Format per entry: what happened, why it's wrong for this project
specifically, the correct alternative.

<!-- Example shape, remove once the first real entry lands:

## Reporting `mix test` as passing without running it

An agent said "the property test should now cover the new transition"
without actually running `mix test`. This violates the No Speculation
rule in `CLAUDE.md` and defeats the point of the property test, which
exists specifically to catch cases a human wouldn't think to assert by
hand (README §4).

**Correct alternative:** run `mix test`, quote the actual output. If
the environment can't run it (no toolchain, no network for
`mix deps.get`), say that explicitly instead.
-->

## No Elixir/mix toolchain on PATH in this sandbox

Agents repeatedly discover (correctly, per the No Speculation rule)
that there's no local Elixir/mix toolchain, and stop at "can't verify."
There's a working alternative: Docker is available. Run a throwaway
`elixir:1.17-otp-27` container plus an isolated `postgres:16` container
on a private Docker network (`docker network create`, then both
containers `--network` onto it, referencing Postgres by container name
as the DB hostname rather than `localhost`). This sidesteps host port
5462 too, which may already be held by another local Postgres
container — don't touch a container that isn't yours.
Mount the repo read-write into the Elixir container
(`-v //c/...:/app -w /app`), run `mix local.hex --force` /
`mix local.rebar --force` once, then `mix deps.get` / `mix compile` /
`mix ecto.create` / `mix ecto.migrate` / `mix test` as `docker exec`
calls. Tear down both containers and the network afterward. On
Windows/Git Bash, bare `/app`-style paths get mangled by MSYS path
conversion — prefix affected `docker run`/`docker exec` calls with
`MSYS_NO_PATHCONV=1`. If `config/test.exs` hardcodes `localhost:5462`,
temporarily change it to read `System.get_env("LETFLOW_DB_HOST",
"localhost")` / a port env var with the same fallback, run the
verification, then revert the config file back to its committed
contents afterward — don't leave the env-var indirection in a tracked
file for a one-off verification run.

**Correct alternative:** try Docker-based verification before reporting
"can't run it" as final — it worked cleanly for REQ-001 (12/12 tests,
including a StreamData property test, against a real Postgres).

## Overwriting `docs/status/requirement_status.yaml` instead of appending

An agent (ELIXIR-DEV, REQ-003) found the file didn't match its
expectations and rewrote it from scratch with a different header
format and field names (`requirement`/`timestamp_utc` instead of the
established `req`/`at`), silently discarding every prior history entry
(REQ-001, REQ-002). The file's own header comment says "Append one
entry per event. Never rewrite past entries" — this is exactly the
mistake that comment exists to prevent. ORCH caught it by diffing
against what it had just written and restored the lost entries.

**Correct alternative:** always read the existing file in full before
touching it, preserve its established schema even if a different shape
seems cleaner, and append (don't replace). If the file is genuinely
missing, use the header/entry shape already documented in this repo's
other status files or CLAUDE.md, not an invented one.

## Extrapolating handoff timestamps instead of reading the clock (ORCH)

During REQ-023's WF-02 run, ORCH stamped each dispatched handoff's
`created_at`/`started_at` by *estimating* a plausible time from the
run's earlier entries rather than running `date -u` for each one. The
estimates crept steadily ahead of the real clock — by the eleventh
handoff (`step-06-doc-updater.json`) they were ~23 minutes fast. That
made the handoff's `completed_at` (correctly clock-read by
DOC-UPDATER as `18:49:40Z`) *precede* its own `started_at`
(`19:08:00Z`), which is exactly the corruption
`docs/agents/shared/HANDOFF_PROTOCOL.md` §3 forbids and
`core-directives.md`'s "Bookkeeping Is Not Optional" section exists to
prevent.

Why this is worth its own entry even though the fix is one command:
the failure is silent and cumulative. Each individual estimate looked
reasonable next to the previous one, nothing in the file's appearance
revealed the drift, and a mechanical check across all eleven handoffs
found ten of them internally consistent — so the error was invisible
right up until it produced an impossible ordering. It was caught only
because DOC-UPDATER read the real clock, noticed the contradiction with
the `started_at` it had been handed, and *reported it instead of
quietly writing a later `completed_at`* to make the file look tidy.
That is the producer/validator principle working on ORCH's own
bookkeeping, and it only worked because the agent refused to smooth
over an inconsistency it had not caused.

Note this is the same shape as the existing `.ToUniversalTime()`
warning in `core-directives.md` — a timestamp that is wrong in a way
the output string does not reveal. Anything a later reader would use to
reconstruct sequence (handoff stamps, `requirement_status.yaml` events,
`orchestrator.log` lines) has to come from the clock, because nothing
downstream can detect that it didn't.

**Correct alternative:** run the clock command immediately before
writing each timestamp, every time — never derive one from another
entry, never round a previous value forward, and never batch-generate
several stamps from a single reading:

```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"
```
```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```

If a bad timestamp has already been committed, correct it *and* record
that it was a reconstruction rather than a measurement (see
`handoffs/WF02-REQ023-20260816/step-06-doc-updater.json`'s
`orch_timestamp_correction` field for the shape) — a silently corrected
timestamp is indistinguishable from one that was right all along, which
defeats the audit trail the correction is meant to preserve.

## Running `docker compose up` from a secondary worktree checkout

During WF02-REQ037-20260817's Step 3b (TEST-DESIGN-VALIDATOR, running from
`~/letflow-wt2`, a secondary git worktree), the agent ran `docker compose up`
in its own checkout directory to independently re-verify a test run,
despite an explicit standing instruction for this worktree (its own
session prompt, not this file) that Postgres is already running and
shared with the primary `~/letflow` checkout's container, and
`docker compose up` must never be run here. Because
`~/letflow-wt2/docker-compose.yml` declares the same host port (5462)
the primary checkout's container already holds, the new
`letflow-wt2-postgres-1` container started successfully (compose
doesn't always hard-fail on a port conflict — here it silently came up
with an *empty* port mapping, `{}`, meaning nothing on the host could
actually reach it) alongside an orphaned `letflow-wt2_letflow_pg`
volume and `letflow-wt2_default` network. The test run's own result
was unaffected (`config/test.exs` points at `localhost:5462`, which
only the pre-existing, correctly-configured container actually
publishes, so the tests transparently ran against the right database
regardless) — but the extra container/volume/network were pure waste,
and a small drift from this could plausibly have collided with the
primary checkout's own container state instead of silently no-op'ing.

**Why this is easy to miss:** the agent's own verification (`mix test`
passing) gave no signal that anything was wrong — a docker-compose
port conflict silently producing an unreachable container is not the
kind of failure a downstream `mix test` PASS would ever surface.

**Correct alternative:** never run `docker compose up`/`up -d` from a
secondary worktree checkout — Postgres for that checkout is already
running via the primary checkout's `docker compose up`, sharing the
same server on a separate database (`MIX_TEST_PARTITION=N mix test`
selects the isolated per-checkout database, not a separate Postgres
server). If a docker-based re-verification is ever genuinely needed
from a secondary worktree, use `docker ps`/`docker inspect` to confirm
the existing shared container is healthy and reachable first, never
`docker compose up`.

## Duplicating an `Ecto.Query.fragment/1` SQL literal instead of sharing it via a module attribute

During REQ-042's `search/2` (`lib/letflow/definitions.ex`), ELIXIR-DEV needed the
same ranking `CASE WHEN ... END` SQL text in two places (`select_with_rank/3` and
`order_by_rank/3`) and first tried to share it via a helper function pinned into
`fragment/1` (`fragment(^rank_case_sql(), ...)`). Ecto rejects this at compile time
with `Ecto.Query.CompileError`: "to prevent SQL injection attacks, fragment(...)
does not allow strings to be interpolated as the first argument via the `^`
operator" -- `fragment/1`'s first argument must macro-expand to a literal binary
known at compile time (`Ecto.Query.Builder.expand_and_split_fragment/2` calls
`Macro.expand/2` and requires the result to already be a binary), not a runtime
value produced by calling a function. ELIXIR-DEV correctly concluded this was a
real Ecto constraint (not a workaround for a mistake) and fell back to duplicating
the literal verbatim in both functions, flagging it for REVIEWER.

REVIEWER (WF-02 Step 2d) verified the constraint empirically (a throwaway
`Mix.install` script reproducing both the failing pinned-helper call and a passing
module-attribute call against real Ecto) and found a third option that satisfies
both the SQL-injection guard and DRY: a module attribute. `@rank_case_sql
"CASE WHEN ... END"` referenced as `fragment(@rank_case_sql, ...)` compiles
cleanly, because `@attr` is inlined as a literal binary at compile time -- it is
not a runtime-pinned value -- so `Macro.expand/2` sees the same kind of literal it
would see from a string written directly in the call. This was ruled FAIL/rework
grounds precisely because it was a real, low-risk, mechanical fix (verified before
requesting it, not assumed) rather than gold-plating: the duplicated literal, left
as-is, would have created a silent-drift risk if a future edit updated the ranking
rule in one call site and not the other.

**Correct alternative:** when the exact same `fragment/1` SQL-text literal is
needed at more than one call site, hoist it to a `@module_attribute` and reference
the attribute at each `fragment/1` call -- never a function call pinned with `^`,
which Ecto rejects outright, and never silent duplication when the attribute
approach is available and its call sites are simple enough that one shared source
of truth is a strict improvement.

## `git checkout --ours`/`--theirs` means the opposite thing during `git rebase` vs. `git merge`

During WF02-REQ031-20260817's Step Final, ORCH hit an add/add conflict on
`docs/issues/ISS-0036.yaml` (a genuine cross-host numbering collision, already a
known class per the ISS-0034/ISS-0035 precedent) and resolved it with
`git checkout --theirs docs/issues/ISS-0036.yaml`, intending to keep `main`'s
version and drop the run's own now-redundant local copy. The run's own
`orchestrator.log`/`registry.json`/`requirement_status.yaml` entries all explicitly
documented this intent ("resolved by keeping main's version via `git checkout
--theirs`" / "this run's local ISS-0036.yaml was NOT merged; main's ISS-0036.yaml
... was kept as-is").

That is backwards. `git checkout --ours`/`--theirs` swaps meaning between the two
commands:
- During `git merge`, `--ours` = the branch you're on (HEAD), `--theirs` = the
  branch being merged in.
- During `git rebase`, this is **inverted**: `--ours` = the commit you are
  rebasing *onto* (the target, typically `main`), `--theirs` = the commit
  currently being replayed (your own feature branch's content) -- because a
  rebase internally does its work as a sequence of cherry-picks of your commits
  onto the new base, and from that internal perspective your own commit is the
  "other" side being applied.

So `git checkout --theirs` during that rebase actually kept the **run's own**
`ISS-0036.yaml` (its SVC-03/INV-5 finding) and silently overwrote `main`'s actual
content -- a different, already-independently-resolved `ISS-0036.yaml` from a
concurrent run (a `valid_review_attrs/1` unused-default-arg fix) -- with it. The
squash-merge then carried that wrong content into `main` permanently. Discovered
only because a *third*, later run (WF02-REQ042-20260817) hit its own conflict on
the same file during its own rebase and, per this project's "never satisfy a gate
by editing what it measures" / independent-verification discipline, ran `git show
origin/main:docs/issues/ISS-0036.yaml` to check the actual content on disk rather
than trusting the prior run's own log narrative -- which is what caught the
mismatch. See `docs/issues/ISS-0039.yaml` for the full incident and fix (no
permanent data loss: git history retained the original resolved content, so it
could be recovered from the commit that first wrote it).

**Why this is easy to miss:** the git command runs cleanly, produces no error, and
the rebase/merge completes -- there is no signal at the time that the flag picked
the wrong side. It only surfaces later, and only if something re-derives the
actual file content independently rather than trusting the resolving run's own
narration of what it did.

**Correct alternative:** during a `git rebase` conflict, don't reach for
`--ours`/`--theirs` from merge-trained muscle memory -- either reason explicitly
about which side each flag means *in a rebase specifically* (or just avoid the
ambiguity: read both versions with `git show :2:<path>` / `git show :3:<path>`,
or open the file and look at the `<<<<<<<`/`=======`/`>>>>>>>` markers directly,
and hand-edit to the intended result). After resolving any conflict this way on a
shared/audited file, independently re-read the resulting file's actual content
before writing a log/status entry that claims what was kept -- don't narrate
intent as if it were the verified outcome.

---

## Reading a whole large file to find one entry in it

**Found:** 2026-08-18, during a prompt-efficiency audit of the agent instruction
corpus (`docs/agents/`, `.claude/agents/`).

Nine role files instructed their agent to read `docs/requirements.yaml` — several
with the words "in full" — as a "Mandatory reading at session start" item. That
file is 3,384 lines and roughly 61,000 tokens, holding 70 requirements, of which
a given run needs one to four. Measured against the mandated preamble for a
single ELIXIR-DEV turn (CLAUDE.md + core-directives + WF-02 + security-invariants
+ anti-patterns + the role file + requirements.yaml), the requirements file alone
was ~76% of roughly 79,900 tokens — more than the other 29 instruction files
combined, by about 25x.

**Why this is easy to miss:** it reads as diligence. "Read the requirements in
full before touching code" is exactly the kind of instruction that looks careful,
and each individual role file states it once, in one line, so no single file looks
bloated. The cost is only visible when you sum what one turn is actually told to
load.

**Why it also costs accuracy, not just tokens:** 33 of those 70 requirements are
`done`, and this project's requirement descriptions are long and densely
cross-referential (REQ-043's alone runs 40+ lines citing four other REQ ids, a
decision record, and two R-Co source paths). Loading all of them buries the one
requirement in scope under other stages' constraints, which is a real chance for
an agent to build against the wrong stage's rules.

**Correct alternative:** carry scoped context in the handoff instead of pointing
at the file. ORCH — which already reads `docs/requirements.yaml` to select work —
copies the in-scope requirement's full `description` into
`context.requirement_text` (see `HANDOFF_PROTOCOL.md` §2), and downstream roles
read it there. Naming the file in `artifacts_in` is *not* sufficient: that still
tells the receiving agent to open it. When a role genuinely must consult the file
for a cross-referenced id, read only that entry:

```bash
awk '/^  - id: REQ-039$/,/^  - id: REQ-04[0-9]$/' docs/requirements.yaml
```

Two roles are legitimately exempt and say so explicitly in their own files —
REQ-ANALYST (global numbering/schema) and REQ-VALIDATOR (cross-requirement
consistency). The general rule now lives in `core-directives.md`'s "Load Scoped
Context, Not Whole Files", and it generalizes past this one file: prefer a
targeted read over a whole-file read for anything above a few hundred lines
(`git diff main...HEAD` over reading every changed file; `grep -n` over reading a
3,000-line YAML to find one key).

## Using `python3 -c "json.dump(...)"` to reorder/rewrite `handoffs/registry.json`

During WF03-ISS0045-20260818's registry bookkeeping, ORCH used a `python3 -c`
script (`json.load` + `json.dump(..., indent=2)`) to fix an out-of-chronological-order
entry it had just inserted. `json.dump`'s default `ensure_ascii=True` silently
rewrote every non-ASCII character in the file to a `\uXXXX` escape — every `§`
character in the file's own `_comment` field and multiple historical entries'
notes became a `§` escape sequence. The diff was caught only because it was reviewed
(`git diff --stat` showing ~1650 changed lines for what should have been a
one-entry move) before committing — a mechanical script produced a technically-valid,
schema-conformant JSON file that nonetheless silently corrupted content across
dozens of unrelated historical entries, exactly the kind of file-format regression
`core-directives.md`'s "Never Satisfy a Gate by Editing What It Measures" and
"Bookkeeping Is Not Optional" sections both guard against in spirit (the file stayed
parseable, so no gate would have caught it).

**Correct alternative:** never round-trip `handoffs/registry.json` (or any other
append-only project file with non-ASCII content) through `json.load`/`json.dump`
for a structural fix. Use the `Edit` tool's string-replacement on the raw text
instead — cut the misplaced JSON block via one `old_string`/`new_string` pair (remove
it from its wrong position) and a second edit to append it at the correct position,
never a full parse/re-serialize round-trip. If a `python3 -c` JSON check is
needed at all, use it read-only (`json.load` to validate parseability) — never
call `json.dump` on a file that contains non-ASCII characters without explicitly
passing `ensure_ascii=False`, and even then prefer a pure text edit over a
round-trip for a file this project treats as append-only/audit-trail.

## Two branches picking the same module name is a real rebase-time collision class, not just an ISS-number collision

WF02-REQ043-20260818 (schema module `Letflow.Engine.Token`, an `Ecto.Schema` for
the `tokens` table) and WF02-REQ044-20260818 (`Letflow.Engine.Token`, a pure
in-memory struct for the transition kernel, EE-02) were developed in parallel from
the same base commit, each unaware of the other. REQ-044 merged to `main` first.
When REQ-043's branch was later rebased onto that updated `main` (after a host
power interruption mid-rebase), `git` reported an add/add conflict on
`lib/letflow/engine/token.ex` — same path, same module name, two structurally
different things (persisted lifecycle row vs. transient pure-function value) that
cannot share one name. The same rebase also hit the already-documented
ISS-number-collision class (this file, above) a second time, independently: main
had already renumbered REQ-043's own `assignee_type` finding from ISS-0042 to
ISS-0043 (`docs/issues/ISS-0043.yaml`, GH#159) after an earlier cross-host
collision with REQ-044's ISS-0042 — so REQ-043's *other* finding (tenant_id
caller-mismatch, originally filed as its own ISS-0043) collided a second time.
A local resolution renumbered it to ISS-0044 first, but a concurrent host
independently ran the identical recovery for the identical branch/finding
moments later and reached `main` first with its own resolution (ISS-0045,
`docs/issues/ISS-0045.yaml`, WF03-ISS0045-20260818) — since `main` already had
an equivalent, fully-diagnosed record of the same finding, the losing side's
own duplicate was dropped entirely on its next rebase rather than filed under
yet another number. This is the concurrent-host race itself as an addition to
the ISS-numbering-collision class, not just a numbering mechanic: two hosts
recovering the *same* interrupted branch independently can each do the
"correct" renumbering and still collide with each other, and the answer is to
check whether `main` already carries an equivalent record before re-filing
one, not to just take the next free number on faith.

## TEST-DESIGNER writing narratively-detailed `describe`/`test` names that exceed ExUnit's 255-char combined limit

**Found:** 2026-08-18, ORCH session-start verification on `main` (commit `e8ef92d`,
before ISS-0049's fix), `mix test` failed to compile entirely.

Three `describe`/`test` string pairs, all from recent TEST-DESIGNER output for the
REQ-063/REQ-064 (Decision 0006) work, packed full acceptance-criteria context inline
into the names themselves — e.g. `describe "provision_oidc_user/4 — username
collision, same tenant schema vs different tenant schemas (REQ-063 acceptance
criteria)"` combined with an equally long `test "..."` string. ExUnit concatenates
`"test " <> describe <> " " <> test_name` into one internal identifier and hard-caps
it at 255 characters (`ExUnit.Case.validate_test_name/1`) — exceeding it is a
`SystemLimitError` at compile time, not a warning, so it doesn't fail one test, it
fails the whole file's compilation and blocks the entire suite (0 tests ran). See
`docs/issues/ISS-0049.yaml` for the full incident; this is the third occurrence of
this exact failure class in this project.

**Why this is easy to miss:** writing a self-documenting test name feels like good
practice, and each individual name looks reasonable in isolation in an editor — the
255-char ceiling only bites when `describe` and `test` are summed together, which
nothing in the file's own diff highlights.

**Correct alternative:** keep `describe`/`test` names as a short label, not a
restatement of the requirement's acceptance criteria — put the "why"/spec citation in
a `#` comment above the test instead of in the name string. TEST-DESIGNER should keep
combined `describe` + `test` name length comfortably under 200 characters (leaving
margin for ExUnit's own `"test "` prefix and separator), and TEST-DESIGN-VALIDATOR
should treat an unusually long describe/test pair as worth a manual length check
before passing the gate, since `mix compile`/`mix test` failing to even start is the
only signal today.

**Update, 2026-08-18 (ISS-0051):** this recurred a *fourth* time
(`test/letflow/engine_test.exs:717-718`, REQ-045/EE-01 work, 259 chars), found by
ISSUE-FIXER while trying to reproduce ISS-0050 on a branch based on current `main` —
confirmed pre-existing on `main` itself, not introduced by that branch. Three
documented recurrences of this exact class had not prevented a fourth. Documentation
alone is evidently not a sufficient gate; TEST-DESIGN-VALIDATOR (or a `mix test`
alias/CI step) should add a mechanical mode-independent check — e.g. a small script
that greps every `describe`/`test` pair and flags any combined length ≥ 200 — rather
than relying on a human/agent noticing during review.

**Correct alternative:** don't silently let the later-merged branch's name win by
accident of rebase order. Confirm which module is already shipped and load-bearing
on `main` (`grep -rl` its call sites — REQ-044's `Token` was aliased from
`instance_state.ex`/`transition.ex`/its own test, i.e. genuinely in use) and rename
the *unmerged* side instead, moving it to a new file/module name
(`token_record.ex` / `Letflow.Engine.TokenRecord`) rather than editing the
already-shipped one. Record the rename's reasoning in the new module's own
moduledoc (not just the commit message) so a future reader who only opens the file
sees why the name doesn't match the original design doc. This is the same
"confirm what's on disk, don't trust the branch's own narrative" discipline the
ISS-0036 incident above establishes, applied to module names instead of issue
numbers.
