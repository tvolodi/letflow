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

**SUPERSEDED 2026-08-19 on this host — CHECK BEFORE ASSUMING.** A local
toolchain IS installed and on disk: `/c/Program Files/Elixir/bin/mix`,
Mix 1.20.3 (compiled with Erlang/OTP 29). Verified this session by running
`mix compile --force` directly (`Generated letflow app`, 0 errors). Bare
`mix` may not be on `PATH` in every shell — invoke it by full path,
quoted, rather than concluding it is absent. **Run
`ls "/c/Program Files/Elixir/bin/mix"` before reporting "no toolchain";
this entry itself went stale and was believed for multiple runs.** The
Docker route below remains valid as a fallback (and is still the way to get
a real Postgres for `mix ecto.*` / integration tests), but it is no longer
the first resort for `mix compile` / `mix format` / unit-level `mix test`.

Original entry, kept for the Docker recipe:

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

**Correct alternative:** start at `docs/status/requirement_status.index.yaml`, read the
**current volume** it names in full — volumes are capped, at the ceilings the index's
`roll_rule:` records, precisely so that read is possible — preserve its established
schema even if a different shape seems cleaner, and append (never replace). Confirm with
`git diff --numstat` that the deletions count for the file is 0. Never edit a closed
volume. If the file is genuinely missing, use the header/entry shape documented in the
index and the current volume's own header, not an invented one.

## Issuing the clock read and the timestamped write as ONE shell command (ORCH)

**Found 2026-08-21, twice inside four minutes, during WF03-ISS0204-20260821's own run
closure — the run that had just finished documenting this exact class.** ORCH wrote its
`RUN_DONE` line as a single command of the shape:

```bash
date -u +"%Y-%m-%dT%H:%M:%SZ" && cat >> handoffs/orchestrator.log <<'EOF'
2026-08-21T10:29:40Z | RUN_DONE | ...
EOF
```

The clock read is *in* the command, so it looks measured. It is not: the literal
`10:29:40Z` had to be composed before the command ran, and the real reading came back
`10:29:12Z` — 28s fast. The correction line appended to fix it was issued the same way
and was 55s fast. **The defect is structural, not a lapse of care.** Batching the two
makes an extrapolated stamp *unavoidable* regardless of how carefully the writer is
trying to follow the entry below; the `date` output is only ever visible after the write
it was supposed to inform.

**Why this is easy to miss:** the command *contains* a real clock read, and its output
is right there in the transcript. Nothing looks wrong — it reads as measure-then-write,
and the two values are close enough that the discrepancy is invisible unless someone
compares them line by line. This is the same "wrong in a way the output string does not
reveal" shape as the `.ToUniversalTime()` hazard and the entry below, arriving through a
different door: not memory, not rounding, but *ordering inside a single tool call*.

**Correct alternative:** read the clock in its **own** tool call, let the value come
back, then write the line in a **second** call using the value returned. Never put
`date -u` and the write that consumes its output in one command — not with `&&`, not
with `;`, not in the same heredoc. If a stamp has already been committed wrong, correct
it by **appending**, never by editing (the log is append-only), and name the mechanism
rather than only the number, so the next reader fixes the cause and not the symptom.

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

## Task-selection fallback duplicating a run (ORCH)

On 2026-08-19, two separate ORCH sessions both selected REQ-048 as "the
next eligible requirement" and independently ran full WF-02 pipelines
for it. `docs/agents/protocols/TASK_QUEUE.md` at the time explicitly
permitted this: if `letflow-queue` was unreachable or
`$QUEUE_AUTH_TOKEN` wasn't set, ORCH was allowed to fall back to
reading `docs/requirements.yaml` directly and picking the first
`pending` requirement with satisfied `depends_on` — reasoned to be safe
in a "single-host session with no multi-host risk." That reasoning was
the bug: a session cannot actually verify it's the only host running
Letflow agents, so "no multi-host risk" was an assumption, not a fact.
One session's fallback-mode run finished and merged REQ-048
(`WF02-REQ048-20260818`, PR #204) while a second session, also lacking
`$QUEUE_AUTH_TOKEN`, independently fell back and dispatched a second
full WF-02 run for the same requirement
(`WF02-REQ048-20260819`). The duplicate was caught only because Step
00's `git pull --ff-only` happened to surface the already-merged
work before any real implementation started — a later-arriving
conflict, not a structural guarantee. `letflow-queue` exists
specifically to make this kind of claim atomic across hosts; a
fallback path that reintroduces unarbitrated file reads defeats that
guarantee exactly in the case it matters most (multiple hosts active
at once, none aware of the others).

**Correct alternative:** fallback selection is now forbidden outright
(`TASK_QUEUE.md`'s Hard Rule, `ORCHESTRATOR.md` §1,
`core-directives.md`'s "No Agent Discretion Over Task Selection"
section). If `letflow-queue` is unreachable, ORCH reports
`no_eligible_task (queue unreachable)` and stops rather than reading
`docs/requirements.yaml` to pick unscoped work itself — even when the
session appears to be the only one running. A specific `REQ-XXX` named
directly by the user remains fine to work on without the queue (the
human made the selection, not ORCH), but ORCH should still attempt to
register/lock it against the queue once reachable.

**Addendum, same day:** the queue was likely never actually unreachable
for either session. `QUEUE_AUTH_TOKEN` lives in two possible places —
the shell environment, and a `.env` file at the repo root (gitignored,
sanctioned local-dev convenience, confirmed with the project owner) —
and both duplicate-run sessions evidently checked only the former. A
live test the same day showed the `.env` token authenticating
successfully against `queue-test.ai-dala.com`. So the proximate cause
wasn't "the queue was down," it was "the check for the token was
incomplete" — `TASK_QUEUE.md` §"The four functions" now says explicitly
to check `.env` before concluding the token is unavailable. The
fallback-forbidden fix above is still correct defense in depth (a
*genuinely* unreachable queue should never trigger self-selection
either), but don't assume every future "queue unreachable" report is
real without first confirming `.env` was checked.

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

Follow-up (2026-08-21): the shared-host-port half of this is now
fixable rather than only avoidable — `docker-compose.yml` publishes
`${LETFLOW_DB_PORT:-5462}` and `config/dev.exs`/`config/test.exs`
resolve the same variable through `config/db_port.exs`, so a checkout
that genuinely wants its own PostgreSQL sets `LETFLOW_DB_PORT` in an
untracked `.env` and gets a container and an Ecto config that agree.
This does *not* license running `docker compose up` in a checkout
instructed to share another one's container — the rule above stands;
it only removes the silent-empty-port-mapping failure mode for
checkouts that are supposed to have their own.

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

## A rebase add/add conflict on `docs/issues/ISS-NNNN.yaml` can land without git ever flagging it as CONFLICT

**Found:** 2026-08-18, ORCH post-merge independent verification of WF03-ISS0050-20260818
(PR #193, merge commit `c9894b2`).

Two concurrent hosts independently discovered and fixed the identical bug (a fourth
occurrence of the 255-char ExUnit test-name class, `test/letflow/engine_test.exs:717-718`)
within 16 minutes of each other, and each filed it as its own `docs/issues/ISS-0051.yaml`
(same path, different content) — the same class of numbering collision documented
elsewhere in this file (ISS-0034/0035, ISS-0036/0037/0039, ISS-0042/0043, ISS-0043/0044-0045).
`WF02-REQ047-20260818`'s commit (`c7a5d4a`) reached `main` first. `WF03-ISS0050-20260818`'s
branch had its own `docs/issues/ISS-0051.yaml` commit created *before* REQ-047 merged, so
Step Final's `git rebase origin/main` had to replay a commit that adds a file at a path
`main` already had different content at — textbook add/add conflict shape. **But the
Step Final agent's own handoff (`step-final-git-merge.json`) reported only one conflicted
file (`handoffs/orchestrator.log`) and never mentioned `docs/issues/ISS-0051.yaml` at
all** — yet the file that landed on `main` is `WF03-ISS0050-20260818`'s content, not
`WF02-REQ047-20260818`'s, meaning REQ-047's own audit-trail record (and its `github_issue`
cross-reference, GH#192) was silently dropped without ever being surfaced as something
requiring resolution. GIT_MERGE.md's own conflict-count check
(`git diff --name-only --diff-filter=U | wc -l`) would have caught this file if the agent
had actually re-run it after resolving the reported conflict, rather than treating the
rebase as fully clean once *a* conflict was resolved. This was only caught because ORCH,
per this project's own "never trust a resolving run's own narrative" discipline, diffed
the pre-merge blob (`git show <pre-merge-sha>:<path>`) against the post-merge file instead
of trusting the Step Final handoff's summary.

**Why this is easy to miss:** the rebase command's own exit code and the agent's own
narration ("one conflict, resolved, tests green") both looked completely clean — nothing
in the visible output distinguished "one conflict occurred and was the only one" from
"one conflict was noticed and resolved, a second one existed and was resolved without
being reported" (or, alternatively, resolved by a stale `git add -A`-style catch-all that
silently staged an unresolved but no-longer-marked-`<<<<<<<`-visible file). Post-merge
`mix test` passing gave no signal either, since both sides' fixes were code-equivalent —
the lost content was pure audit-trail, not a behavior regression, so no test could ever
have caught it.

**Correct alternative:** after `git rebase --continue` reports success, re-run
`git diff --name-only --diff-filter=U | wc -l` one more time as a hard check (must be
`0`) before proceeding to push — do not rely on having "handled a conflict" once as proof
none remain. When a run adds a new file under `docs/issues/` (or any other append-style
directory this project treats as collision-prone), diff the specific file's pre-rebase
and post-rebase blobs (`git show ORIG_HEAD:<path>` vs current) as a final check even when
git reported the rebase as conflict-free for that path — a silently-applied patch that
happened not to conflict textually can still be the wrong side's content in a genuine
add/add scenario, and only a content diff (not the exit code) reveals it.

## Two independently-merged Ecto migrations picking the same version-number prefix

**Found:** 2026-08-19 (ISS-0061), discovered by `hetzner-orch` when `mix ecto.migrate` /
`mix test` on `main` failed hard before a single test ran.

`priv/repo/migrations/20260819000001_create_groups_tenant_scoped.exs` (REQ-063,
Decision 0006 D1) and `priv/repo/migrations/20260819000001_drop_transition_events.exs`
(REQ-046, `process_instance.ex` retirement, #199) were developed on independent hosts,
each derived its migration's version prefix from its own host clock at commit time, and
both merged to `main` independently (commits `5941472` and `1059093`) without either
host observing the other's concurrent migration. `mix ecto.migrate` — and therefore
`mix test`, which runs pending migrations against the sandbox DB before any test body
executes — failed immediately with `Ecto.MigrationError: migration version
20260819000001 is duplicated`, blocking every host working this backlog, not just the
run that happened to find it first. Fixed in PR #211 (WF03-ISS0061-20260819) by
renumbering one of the two files to a later, non-colliding version.

This is the same cross-host filename/id collision class already documented above ("Two
branches picking the same module name...", the `docs/issues/ISS-NNNN.yaml` add/add
entry) but the first occurrence against an Ecto migration version number specifically,
and it is worth distinguishing from those two: a colliding module name compiles cleanly
and is only caught later by a build/test failure somewhere downstream, and a colliding
`docs/issues/ISS-NNNN.yaml` filename can land through a rebase without git ever
flagging it as a conflict at all. A colliding migration version is a *harder* failure —
Ecto's own duplicate-version guard raises `Ecto.MigrationError` immediately, before any
application code runs, so it is impossible to silently ship (unlike the other two,
which can persist on `main` for a while before anything notices).

**Why this is easy to miss:** each host generates its migration's timestamp prefix from
its own local clock at the moment the migration is created, with no cross-host
coordination step in between — two hosts working the backlog concurrently, each
starting from the same base commit, have a real chance of picking timestamps that land
in the same second-granularity bucket, especially when migrations are authored close
together in wall-clock time. Nothing about either individual branch looks wrong in
isolation; the collision only exists once both have merged into the same `main`.

**Correct alternative:** `test/letflow/migration_filenames_test.exs` (added in the same
ISS-0061 fix) is now a standing regression guard — it asserts no two files under
`priv/repo/migrations/` share a leading version prefix, and that every migration
filename's prefix is purely numeric, so a second occurrence fails `mix test` on the
merging host's own branch (or on `main` immediately after a bad merge) rather than
surfacing only when some other host next tries to migrate. Rely on that test rather than
manually eyeballing timestamps before a migration PR merges. The deeper mitigation this
incident points to — ORCH preferring a coarser/higher-entropy migration timestamp source
(e.g. including seconds *and* a host-specific salt, or checking
`docs/agents/protocols/GIT_SETUP.md`'s branch-push coordination signal more carefully
when multiple hosts are adding migrations concurrently) — is out of scope for this entry;
flag it if it recurs a second time.

## Inheriting a claim from a record instead of re-deriving it from the source

**Occurred three times in one session (WF01-REQ109-20260819), each time compounding the
last.** Every instance had the same shape: an agent read a *claim in a Letflow record*,
treated it as established fact, and built work on top of it — when the underlying source
was reachable the whole time and said something different.

1. **ISS-0063's original scoping note.** ISSUE-FIXER concluded the issue was blocked on
   an undecided product question ("where does a `:HUMAN_TASK` node's output schema come
   from?", REQ-047 OQ-3) and wrote that conclusion into the issue file as fact. Reading
   R-Co directly showed three different things there carry the word "schema", that the
   investigation had conflated two of them, and that `tasks.form_schema` is a UI
   rendering payload never used for validation. The real source (`variable_schemas`) had
   existed in R-Co the entire time. **A wrong-but-confident record is worse than an open
   issue**, because the next agent inherits the frame instead of re-deriving it.
2. **ISS-0076's own file list.** Filed by ORCH to warn about exactly this class of
   problem — and its `affected_files` was derived *from* its own recommended grep
   pattern, so list and pattern were self-consistent and blind together. It missed four
   files including a fourth shipped moduledoc (`lib/letflow/engine/execution_error.ex`).
   Its "30 occurrences" counted `docs/`, i.e. the record counting itself.
3. **REQ-111's premise.** ORCH scoped a whole requirement around auditing
   `req062-sub-process-runtime.md`'s `instance.zig`/`transition.zig` line citations,
   inherited from ISS-0076's framing. There are **zero** such citations — the file
   mentions those R-Co files in prose only, and all ~55 of its `file:line` citations
   point at *Letflow* files, two of them at `transition.ex`, one character from
   `transition.zig`. The caveat it was built around is a standing disclaimer guarding
   citations the document never made. Caught only by REQ-VALIDATOR running the grep.

**Why this is easy to miss:** the inherited claim is usually *plausible*, written by a
competent agent, and sitting in the exact file you were told to read. Nothing looks
wrong. The failure is invisible precisely because the record is the normal, sanctioned
input — and each downstream agent that trusts it adds authority to the error rather than
catching it. Prose caveats are especially dangerous: a sentence like "no R-Co source tree
is reachable in this environment" was true for the host that wrote it and silently false
for every host after.

**Correct alternative:** when a record makes a *checkable* claim that your work depends
on — a file exists, a citation resolves, a count is N, a source is unreachable — spend
the one command it takes to check it before building on it. Specifically:

* **Verify the premise before scoping work around it.** If a requirement's whole point is
  "audit the citations in X", grep for the citations first. Zero is an answer.
* **Never derive a file list and a search pattern from each other**, then cite one as
  evidence for the other. Measure with a deliberately broader pattern than you think you
  need, and make counts an *output* of the run rather than a constant copied forward.
* **Scope greps to the code being described.** ISS-0076's inflated count came from
  including `docs/`, where the issue files themselves live.
* **Treat "unreachable/unavailable in this environment" as expiring.** It is a statement
  about one host at one moment, not a property of the project. R-Co is at
  `c:\Users\tvolo\dev\ai-dala\R-Co` and is readable; check before repeating the claim.
* **When you do correct such a record, supersede rather than overwrite** — ISS-0063
  keeps the wrong note as `superseded_scoping_note` marked do-not-act-on, so the audit
  trail survives without the error staying live.

**A fourth instance landed 2026-08-21** (ISS-0106's `ROOT CAUSE (confirmed, not
inferred)` line, inherited into its own proposed resolution and refuted by one container
run) — filed separately below as "Attributing a failure to toolchain drift without ever
running the pinned toolchain", because its refutation is specific enough to be worth its
own procedure.

## Audit-shaped requirements: closed-set and outcome-independence must be checked at draft time

**Twice in one session the gate had to repair the same property after the fact**
(REQ-110/111/112). Requirements whose deliverable is *findings* rather than *code* have a
failure mode ordinary requirements don't: an acceptance criterion that presumes a finding
is unsatisfiable exactly when the audit succeeds at finding something unexpected. "REQ-059's
override mechanism matches R-Co" reads as a reasonable AC and is actually a trap — an
honest auditor who finds a mismatch fails it.

The sibling defect is a **disposition set that isn't closed**. ORCH's first set was
`confirmed / corrected / filed-as-issue`, which has no slot for a question the source
*cannot* answer — and one target (`req060-pin-rebind.md:100`) says in its own text that
it isn't something R-Co could settle, being a Letflow caller-responsibility choice. Under
that set an auditor must either leave the location unaddressed (failing an AC) or force a
false disposition. A fourth outcome, `unsettled_by_source`, fixed it. The identical gap
then reappeared one requirement over in REQ-111, whose set was closed for *citations* but
not for a substantive assumption that might "differ, but harmlessly".

**Correct alternative:** when drafting an audit-shaped requirement, run the closure test
as a *drafting step*, not as something the gate discovers — for each location in scope,
enumerate the plausible outcomes and confirm every one has a slot. Then write ACs that
quantify over **locations, never over outcomes**: every location resolves to exactly one
disposition, each carrying concrete `file:line` evidence, with counts that must sum so
partial completion shows up as arithmetic rather than prose. Add an explicit nil-result
clause so "found nothing" is a *stated* result rather than an inferred absence — that
closes the "looked and found none" vs "never looked" ambiguity. A meta-AC forbidding
satisfaction by global verdict is worth including: it stops one block judgement standing
in for N per-location ones, which is exactly what hides a single wrong rule among several
right ones. Where a disposition could become a lazy catch-all, fence it by requiring the
specific source `file:line` consulted *and* why it doesn't settle the question — a shrug
can't produce either.

## Picking the next `ISS-NNNN` with `ls docs/issues/ | tail -1` is not atomic — it silently destroyed a record

**Happened for real on 2026-08-19, not hypothetically.** Two agents were running
concurrently on the same host. REQ-110's ISSUE-FIXER wrote its pin-override finding as
`docs/issues/ISS-0077.yaml` and filed GH#298 under that id. A concurrent
`WF02-REQ109-20260819` CODE-DESIGNER independently picked the same next-free number for an
unrelated `VariableMerge` finding, and **its file landed second, overwriting the first**.
No git conflict, no error, no warning — the second `Write` simply replaced the first
agent's file. It was recovered only because the first agent still had the content in its
own context and could renumber to `ISS-0079` and repoint GH#298's body. Had it been
compacted out, or had the agent finished earlier, the record would have been gone with a
live GitHub issue pointing at a file describing something else entirely.

**Why the usual defences don't catch it:** this is an add/add of the *same path*, so it
isn't the rebase-collision class already documented above — both writes happen in one
working tree, seconds apart, before either is committed. `git status` shows one untracked
file, which looks correct. Nothing in `docs/agents/protocols/ISSUE_QUEUE.md` serialises
id allocation, and the "highest existing + 1" convention is a read-then-write race with no
lock between the two halves. The risk scales with exactly the thing this pipeline
encourages — running producing agents in parallel.

**Correct alternative — for whoever is coordinating, not the sub-agent:**

* **Allocate ids centrally.** When dispatching concurrent agents that may file issues,
  hand each a *reserved, disjoint* range in its brief ("use ISS-0081 and upward"), rather
  than letting each derive its own from the directory. The coordinator knows what is in
  flight; a sub-agent does not.
* **Never overwrite an existing `docs/issues/ISS-NNNN.yaml`.** If the target path already
  exists, that is a collision — take the next free id, do not merge and do not replace.
  A `Write` to an existing issue path should be treated as a bug regardless of content.
* **File the local record before opening the GitHub issue**, and put the id in the GH
  title. A GH issue whose body cites a local file that has since been overwritten is the
  worst end state, because the two records disagree while both look authoritative.
* **When you do hit a collision, renumber your own and leave the other intact** — that is
  what happened here and it was the right call. Then fix the GH body, and say so in the
  handoff so the coordinator knows the numbering is no longer dense.

## `ISS-NNNN` collisions keep recurring because documenting the hazard doesn't reserve the number

**Fired again on 2026-08-20**, during `WF02-REQ066-20260820`'s Step Final — the seventh
recorded instance of this class (ISS-0034/0035, ISS-0036/0037/0039, ISS-0042/0043,
ISS-0043/0044-0045, ISS-0051, ISS-0077/0079, and now ISS-0107). What makes this one worth
adding is *not* the collision itself, which the entries above already cover, but that the
run **predicted it in advance, wrote the mitigation into the Step Final handoff, and it
happened anyway** — because a warning is not a lock. While the branch was in flight, a
concurrent session (the letflow-2 workspace, PR #356) independently allocated `ISS-0107`
for an unrelated Windows fake-mix issue and merged to `main` first. The rebase produced an
add/add on `docs/issues/ISS-0107.yaml` plus a follow-on *content* conflict, because a
later commit in the same branch had backfilled `queue_task_id`/`github_issue` into what
was, post-resolution, main's file rather than this run's.

The resolution was correct and is the shape to copy: neither `--ours` nor `--theirs` was
used at any point (both stages read via `git show :2:` / `git show :3:` and identified by
content), main's record was kept byte-identical, and *this* run's record was renumbered to
`ISS-0109` — the next id genuinely free across every remote branch, not merely free
locally — carrying a `renumbered_from` field so the audit trail survives. ISS-0108's three
cross-references were repointed and GH#358's body was updated to cite the new filename
while keeping its issue number. Historical handoffs and the Step 4 test report still say
"ISS-0107" and were deliberately left as written rather than retroactively edited.

**A second finding from the same resolution, worth its own note:** the post-rebase
verification was done by *content diff*, per the existing "an add/add on this path can
land without git flagging it" entry above — and that is what revealed `ISS-0106`'s raw
diff showing every single line as changed. The cause was purely `LF`→`CRLF` checkout
conversion on Windows, confirmed with `diff --strip-trailing-cr`. An agent trusting the
raw diff would have concluded a file had been rewritten when nothing had changed at all;
an agent trusting the exit code would have missed a real overwrite. Both failure modes
are avoided only by diffing content *and* normalising line endings before judging it.

**Correct alternative — the structural fix, not another warning.** The prior entries
already say "allocate ids centrally" and "never overwrite an existing
`docs/issues/ISS-NNNN.yaml`", and this run followed both and still collided, because the
coordinator can only reserve ranges for agents *it* dispatched — it has no visibility into
another host's concurrent session. Until `ISSUE_QUEUE.md` gains a real reservation
mechanism (the obvious candidate: derive the id from `register_task`'s returned
`impl_order`, which is already globally unique and atomically allocated by the one service
that spans hosts, rather than from a directory scan), treat an ISS-number collision at
rebase time as *expected* rather than exceptional: scan `docs/issues/` across every
**remote** branch before picking a number, and renumber your own side on conflict as a
matter of routine. Do not read the absence of a collision in one run as evidence the
convention is safe.

**UPDATE 2026-08-21 — the structural fix has landed and is deployed. The scan-and-renumber
routine above is superseded for NEW issues.** (Appended, not a rewrite: everything above
this paragraph is the historical account and stands as written.)

An eighth occurrence fired first, and it is the strongest evidence in this entry precisely
*because* the run did everything this entry told it to. `WF03-ISS0106-20260821` scanned
`docs/issues/` across **every remote branch** before choosing — the exact mitigation
prescribed above — found the highest anywhere to be `ISS-0109`, and filed `ISS-0110` and
`ISS-0111`. A concurrent session (`WF03-ISS0109-20260821`, PR #371) had meanwhile
allocated `ISS-0110` through `ISS-0117` and merged first. Both records had to be renumbered
at Step Final, to `ISS-0118` and `ISS-0119` (see their `renumbered_note` fields). The scan
was not done carelessly; it was correct at the moment it ran. The colliding numbers simply
did not exist on any branch yet. **A scan reads state; it cannot reserve it.** That is why
no amount of scanning discipline was ever going to close this class.

The fix is exactly the mechanism this entry named as "the obvious candidate": the id is now
derived from `register_task`'s own atomically-allocated task id, not from a directory scan.
`letflow-queue` PR #4 (merge `5b0e968`) shipped it and it is deployed on
`queue-test.ai-dala.com` (CD run 32450296100, 2026-08-21T05:23Z), verified live by ORCH.
Concretely:

- `register_task` returns a new **`issue_ref`** field — `"ISS-"` plus the zero-padded task
  id (task 187 → `"ISS-0187"`), `null` for requirement-type tasks. That value **is** the
  issue id and the local record's filename. The queue's `id` is an autoincrement primary
  key, so two hosts can never receive the same one.
- For issue-type tasks the service also rewrites the title to carry that ref as a prefix,
  replacing any `ISS-NNNN:` the caller supplied. A verification probe deliberately titled
  `"ISS-0120: ..."` came back as id 187 / `issue_ref "ISS-0187"` with the title rewritten
  accordingly. Only a *leading* token is replaced — an `ISS-` reference elsewhere in a
  title is a real cross-reference and survives verbatim.
- `register_task` also accepts an optional `github_issue_number` and adopts that issue
  rather than opening a second one; a number already linked to another task is rejected
  (`has already been taken`), not re-pointed.

`docs/agents/protocols/ISSUE_QUEUE.md` has been updated accordingly: its Procedure no
longer contains a "scan and increment" step at all, and its new "Where the id comes from"
section carries the details.

**What is superseded, and what is not.** Superseded for **new** issues: "scan every remote
branch before picking a number," "treat a collision at rebase time as expected," and — from
the entry immediately above this one — "file the local record before opening the GitHub
issue, and put the id in the GH title." That last one inverts: `register_task` creates the
GitHub issue *while* allocating the id, so the GH issue now precedes the local file by
design. It is safe in a way it wasn't before, because the overwrite hazard that advice
guarded against was a *consequence* of guessed numbering rather than of ordering, and
because the id now reaches the GH title automatically instead of depending on an agent
remembering to put it there. Continuing to follow the old advice would mean continuing to
guess a number, which is now the harmful path.

**Not** superseded: everything about handling a collision among the **existing**
hand-numbered records (`ISS-0001`..`ISS-0119`), the renumber-your-own-side-and-leave-the-
other-intact rule, `renumbered_from` provenance, the never-overwrite-an-existing-issue-file
rule, and the content-diff-with-line-ending-normalisation verification finding above —
those remain correct and are the only guidance for anything filed before 2026-08-21.

One consequence to expect rather than investigate: issue ids **jump** from `ISS-0119` to
the queue-allocated range (`ISS-0186` and upward) and are **non-contiguous** thereafter,
because the id sequence is shared with requirement-type tasks. There are no `ISS-0120`
through `ISS-0185` files and there never were. A future reader finding that gap should not
go looking for lost records.

## Working a user-named GitHub issue without ever locking it in letflow-queue

An ORCH session resolving ISS-0086/GH#303 (a user-named, directly-selected issue —
exempt from the queue's Hard Rule *selection* requirement) treated that exemption as
covering the queue entirely: it branched, fixed, tested, and merged the whole run
without ever calling `set_lock`/`get_next_task` to actually claim the task, and without
`release_lock` at the end. Two separate mistakes compounded:

1. **Reachability was tested with `get_next_task` used as a probe.** A throwaway
   `agent_id: "probe"` call meant only to check the service was up actually claimed and
   locked a real, unrelated task (#161, ISS-0075) — `get_next_task` is not read-only, it
   atomically claims whatever it returns. Caught and released immediately, but it should
   never have happened: `GET /health` is the reachability check with no side effects.
2. **The exemption from *selection* was read as an exemption from *locking*.** Nothing
   in the queue's state reflected that ISS-0086 was being worked on. For the entire
   duration of the fix, a second host's own `get_next_task` call could have independently
   claimed the same still-open GitHub issue (if/once it entered the queue's GitHub-import
   side effect) and duplicated the work — the exact failure mode `TASK_QUEUE.md` was
   written to prevent, just via a different door than the one its Hard Rule closes.

**Root cause traced further back, not just this run's own shortcut:** `ISSUE_QUEUE.md`
(the protocol that filed ISS-0086 in the first place) never called `register_task` at
all — it predates `letflow-queue` and was never reconciled with it, so issues filed that
way only enter the queue *opportunistically*, as a side effect of some later
`get_next_task` call's GitHub-import step, if at all. There was no `queue_task_id`
recorded anywhere for ISS-0086, so even a well-intentioned attempt to lock it correctly
had no known id to target — confirmed empirically: one real `get_next_task` claim
attempt this run returned a completely different, newer issue (#163/ISS-0088), not the
one being worked, and had to be released back untouched.

**Correct alternative:** `ISSUE_QUEUE.md` now routes every newly-filed issue through
`register_task` (task_type: "issue") at filing time, recording the returned id as
`queue_task_id` in the issue's yaml — see that file's 2026-08-20 update. For a
user-named task with a `queue_task_id` already on record, `set_lock` it directly before
starting work (it locks any unlocked known-id task, not only a task the same agent held
before — see `TASK_QUEUE.md`'s `set_lock` section). For a legacy issue with no recorded
id, make exactly one real `get_next_task` call to check/claim, release-and-report on a
mismatch rather than chasing further down the stack, and `release_lock(status: "done")`
whatever was actually locked once the fix is merged — full bounded procedure in
`TASK_QUEUE.md`'s "A human names a specific issue" section. Test queue reachability with
`GET /health`, never with a disposable `get_next_task` probe.

## Validating a design's type table for well-formedness instead of against its own normative section

During WF03-ISS0109-20260821, a design artefact declared §3.5 normative for
`capture_schema_state/1`'s failure boundary (an invariant row, INV-F-4, said so in
as many words), and §3.5 required a scalar whose query failed to degrade to `nil`.
Meanwhile the `@type` table in §3.2 typed the same two fields `boolean()`. Both
could not hold.

CODE-DESIGN-VALIDATOR gated this design **twice** — a full first pass that
independently re-derived six load-bearing claims from source (including one settled
by running a real query against Postgres), then a narrow re-gate — and neither pass
caught it. Not from carelessness: each section was checked, and the type table was
internally well-formed. Nothing was checked *across* the two, in the one direction
the design itself had declared authoritative.

It was caught by ELIXIR-DEV, one step later, only because implementing the type
forced the two readings into the same file. That is the expensive place to find it —
and it was found there only because the implementer flagged the contradiction to
REVIEWER instead of quietly picking whichever reading was easier to code.

Why it mattered rather than being a cosmetic type widening: taking the literal
`boolean()` would have broken INV-F-10. A capture whose `information_schema.schemata`
query failed would report `schema_present?: false`, the reason-builder would emit
"schema is absent", and the completeness assertion would raise against a perfectly
healthy schema — a failing *diagnostic* turning a *passing* test red. For a helper
whose entire purpose is making an intermittent failure attributable, reporting an
unobserved thing as an observed absence is the exact defect it exists to prevent. It
would have re-created ISS-0109's original misdiagnosis (see that record's
`mechanism:` correction) inside the very tool built to stop it.

**Correct alternative:** when a design names one section normative over another —
"§X is authoritative", "see §Y for the contract" — that declaration is itself a
checkable claim, and a validator must read the two sections **against each other**,
not each on its own. Concretely: list every field, error value or return shape the
normative section constrains, then look up each one in every other section that
restates it, and diff the two by hand. Any restatement is a place the design can
contradict itself, and a `@type` table is the most likely restatement to drift,
because it is written once and then never re-read while the prose around it changes.
## Attributing a failure to toolchain drift without ever running the pinned toolchain

**ISS-0106, filed 2026-08-20, resolved 2026-08-21.** The issue recorded its cause under
the heading `ROOT CAUSE (confirmed, not inferred)`: this Windows host runs Elixir
1.20.3/OTP 29 while `.tool-versions` pins 1.18.3-otp-27, so the four files failing
`mix format --check-formatted` and the fourteen `struct for X is expected on struct
update` warnings were both artefacts of the host being wrong. Nothing had been run under
1.18.3 to establish that. The issue's own proposal (a) followed from the framing:
"install the pinned toolchain and confirm both checks go green with **no file changes at
all**, which would prove the files are correct and only the host was wrong."

WF03-ISS0106-20260821 ran that check, and the premise failed for half the issue:

* **Format — refuted.** Inside a throwaway `elixir:1.18.3-otp-27` container, against the
  same tree with the repo mounted read-only, `mix format --check-formatted` exits 1 on
  **the same four files with character-for-character identical diffs** —
  `lib/letflow/engine/pin_resolver.ex:541`, `lib/letflow/engine/variable_merge.ex:92,98`,
  `test/letflow/engine/pin_resolver_test.exs:239,322`,
  `test/letflow/engine/pin_rebind_test.exs:516`. That includes the heredoc escape
  ISS-0106 attributed *specifically* to a formatter behaviour change between versions —
  the formatter wants an escaped `\"""` inside the `@moduledoc` heredoc where the file
  has a bare `"""`. Elixir 1.18.3's formatter wants that escape too.
* **Compile — confirmed.** 14 struct-update warnings under 1.20.3/OTP 29, **zero** under
  1.18.3/OTP 27, identical tree. That symptom really was version drift, and it is now the
  measured answer to the `UNCONFIRMED` note ISS-0046 left behind for the same warning
  class.

The four files were not made unformatted by a version change; they were made unformatted
by three commits that merged on 2026-08-20 — `91d7e25` (ISS-0080/GH#301), `cb43cc2`
(ISS-0078/GH#299, PR#347) and `a7fa87b` (GH#298, PR#349). Verified per file rather than
inferred from blame alone, using ISS-0008's `git show <rev>:<path> | mix format
--check-formatted -` technique so nothing had to be written to the working tree: all four
files exit 0 at the introducing commit's **parent** and exit 1 at the commit itself.
*Why* those runs' format gates did not stop them is a separate, still-open question —
tracked as ISS-0110/GH#363, deliberately not answered here.

**Why this is easy to miss:** the attribution was plausible, confidently worded, and
**half right** — a genuine toolchain drift did exist alongside the real defect, and the
correct half lent credibility to the incorrect half. A version mismatch is also a
satisfying explanation for a formatting diff, because formatter output genuinely does
change between Elixir releases sometimes. And the refuting measurement was available the
entire time and cost one container run: Docker was on the host, and this very file
already documents the throwaway-container recipe (`MSYS_NO_PATHCONV=1`, repo mounted
`:ro`, tree copied to `/work`, separate build path). Nobody ran the pinned toolchain
before asserting what it would do. The consequence was concrete rather than theoretical:
a real defect sat deferred for a day as an environment problem — and ISS-0106 predicted
that consequence in the abstract while being an instance of it.

**Correct alternative — refute it cheaply first, and note that this one needed no
toolchain at all.** Three of the four diffs are ordinary line wraps, measured at 99–102
characters against the formatter's default `line_length` of **98**, which `.formatter.exs`
never overrides. *A line over 98 characters is unformatted under every Elixir version
that has ever had a formatter.* `awk '{ if (length($0) > 98) print FILENAME":"FNR": "
length($0) }'` settles it in one command — no container, no install, no second host, no
network. So:

* **Before attributing a formatting failure to a version, measure the diff against the
  configured `line_length`.** If the offending lines are simply too long, the version
  question is moot and the files are wrong under every version.
* **Never write `ROOT CAUSE (confirmed)` for a claim about a toolchain you have not
  run.** "Suspected — not yet reproduced under the pin" is the honest wording and costs
  nothing; the confident wording is what propagates.
* **When one symptom's attribution is confirmed, re-derive the others separately.** Two
  symptoms failing the same command is not evidence they share a cause. Here they did not:
  one was drift, one was a defect, and bundling them made the defect inherit the drift's
  excuse.
* **Run the check the issue itself proposes before proposing anything downstream of it.**
  ISS-0106 named the decisive experiment in its own proposal (a). It just was not run.

This is a fourth instance of **"Inheriting a claim from a record instead of re-deriving it
from the source"** above, and it is filed separately only because its transferable lesson
is specific — version-attributed failures have a cheap, toolchain-free refutation that the
general entry does not name.

## Re-deriving the count while inheriting the unit being counted

**A re-derivation that recounts *how many* but inherits *what is being counted* is not a
re-derivation.** It is a passing run of a different measurement — the same shape as
`core-directives.md`'s **"Re-derive under the conditions the property is actually about"**,
and a variant of **"Inheriting a claim from a record instead of re-deriving it from the
source"** above. This entry exists separately because of who carried it: in every instance
of that entry, the carrier is a *producer* trusting a record, and the correction mechanism
assumed throughout is that a validator re-derives. **Here the validator did re-derive, and
propagated the error anyway** — a gate handoff was itself the carrier, which had not been
recorded before.

**The incident (WF03-ISS0117-20260821), traced by reading each handoff rather than the run
narrative.** One wrong figure — "five occurrences" of an ad-hoc `orch_*` bookkeeping key —
travelled through four steps, and each step re-derived something:

1. **Step 1 (ISSUE-FIXER), `step-01-diagnose.json`** — "Five occurrences across four runs",
   then enumerates **five** run ids, one of which (`WF02-REQ043`) wrote no key at all. The
   unit was already conflated at origin: *occurrences of an improvised key* had been mixed
   with *incidents of an agent dying*.
2. **Step 3 (DOC-UPDATER), `step-03-amendment.json`** — copied it into the protocol as
   "THREE key names across FIVE occurrences", with a parenthetical enumerating **four**.
   The figure and its own evidence list disagreed inside one sentence.
3. **Step 3b (REVIEWER), `step-03b-reviewer-gate.json`** — a gate, correcting *that exact
   paragraph*. It recounted and **refuted** "five occurrences" → four. Then it proposed as
   the fix: "five DEATH incidents across FIVE runs, four of which improvised a key." It had
   re-derived the count and inherited the unit: it matched on **key names and run ids** and
   never opened the keys.
4. **Step 3c (DOC-UPDATER)** — read the four keys' **values**. Two (`WF02-REQ023`,
   `WF02-REQ037`) are ORCH correcting a timestamp, in runs where **no agent died**. Three
   deaths, not five. The correction came from reading content, not from counting harder.

**And it fired a fifth time, in this same run, inside the gate that had just named it.**
Step 3d's re-gate re-derived the death count independently and got **three** — while
inheriting the class boundary from the table it was checking. Re-swept here at Step 3e:
`WF02-REQ038-20260817` is a **fourth** death in the same class (a dispatched
CODE-DESIGN-VALIDATOR killed by a connection error mid-work, redispatched). It was missed
because its dispatch committed nothing, so it left no handoff file and no
`orchestrator.log` line — it survives only in a `registry.json` run note, and a sweep whose
unit is "handoff files carrying a death marker" structurally cannot see it. Same mechanism,
one level up.

**Then a sixth time, one level up again — and the escalation is the transferable part.** The
Step 3f gate re-derived the class *boundary* as dispatched, and found that the section's
**exclusion set** had been enumerated by the same handoff-file-shaped sweep that missed
`WF02-REQ038`: it named one excluded incident and read as though that were all of them, while
`WF02-REQ019-20260816` sat outside it, in-class on treatment and out-of-class on the test, and
undecidable either way because the section stated a class *name* and no membership *test*.
Trace the four numbered steps above and the shape is unmistakable: the error moved from the
**count** (four keys, three deaths), to the **class** (which deaths count), to the
**exclusion set** (which
non-members have been checked for) — and each move survived a re-derivation that was genuinely
diligent *within the frame it inherited*. Re-deriving one level down from where the defect
lives always confirms the defect. So the corrective is not "re-derive harder" but **name the
level you are re-deriving at, and check the level above it once**: if you are recounting
members, re-derive the membership test; if you are checking the test, re-derive whether the
set of things it was applied to was itself assembled by a sweep with the same blind spot. The
fix that finally held was to write down a test a reader can apply to a candidate and get the
same answer as anyone else, and to state the exclusion list as *what has been checked* rather
than as *what exists*.

**Why it is easy to miss.** Re-deriving *feels* like the diligent path, and it is — the
count really is recomputed, from the real files, by a real command. What is never
recomputed is the category the command selects on, because it arrives inside the question.
A gate is *more* exposed to this than a producer, not less: a gate is handed the claim as a
proposition to check, and checking a proposition tends to mean testing its predicate, not
its subject.

**Correct alternative — re-derive the unit, not only the number:**

* **Before recounting, write down in one sentence what a single member of the set *is*,**
  and check that sentence against the source rather than against the claim. "Four keys" and
  "four deaths" are different sets that were the same size for a week.
* **The cheap test: open a sample of the underlying records and read their CONTENT** — the
  key's *value*, the run note's *text* — rather than matching on the field name, key name,
  or id that defines the category. Four `orch_*` keys took two minutes to read in full, and
  reading them is what broke a figure three agents had passed along.
* **Ask what a member of the class would look like if it left no artefact of the kind you
  are grepping for.** `WF02-REQ038` left no handoff file; `WF02-REQ043` left no key. A sweep
  over one artefact type silently defines the class as "members that produced that
  artefact."
* **When a figure and its own parenthetical disagree, stop and re-derive the unit** — not
  the arithmetic. That mismatch was visible in writing at step 2 and was read past twice.
* **A validator correcting a figure must re-derive the corrected figure too.** A replacement
  number offered inside a BLOCKER carries the gate's authority and is exactly as likely to
  be inherited downstream as the one it replaces.

## Overwriting a handoff's dispatched `task` block with a pointer to a copy that does not exist

**During `WF03-ISS0117-20260821`, a completing agent replaced ORCH's 6,290-character
dispatched `task.description` with a 156-character pointer** reading "See the PENDING copy
of this handoff for the full seven-check scope (A)-(G) as dispatched." There is no PENDING
copy: it is the same file, in the same path, and `status` had just been moved to
`COMPLETED` in it. The file was untracked until that same commit, so the dispatched text
existed in **no git object** and survived only in ORCH's live context, from which ORCH
restored it verbatim. Measured on the commit and the working tree: 156 characters committed,
6,290 restored.

**Nothing about the step's verdict or evidence was affected** — this is a record-integrity
fault, not a wrong result, and it should not be reported as more than that. Its value is
that it is a live instance of the gap the same run's amendment was written to close, one
field further along: `§3`'s ownership table then bound `created_at`, `started_at`,
`completed_at`, `status` and `result`, and not `task`.

**Why it happens:** the handoff is the agent's own working file and it edits that file at
completion, so shortening a long block it has already read feels like tidying rather than
deleting. The dispatched text reads as *input already consumed* rather than as *the record
of what was asked*.

**Correct alternative:**

* **Never modify your handoff's `task` block** — it is ORCH's field and the only record of
  what was dispatched. `HANDOFF_PROTOCOL.md` §3's table now says so with no exception.
* If the block is wrong, stale or impossible, **say so in `result.issues`** (per §1.1) and
  leave it intact. ORCH is the only role that can re-dispatch.
* **Never point a record at "the other copy" of itself.** If the pointer names no distinct
  path, it names nothing.
* **Commit the handoff at dispatch, not only at completion.** An untracked file has no
  prior version to restore from; here the text survived by luck — the dispatching session
  happened to still be alive.
## An instruction whose mechanism has silently become unexecutable

`docs/status/requirement_status.yaml` grew past the Read tool's 256KB limit on
2026-08-18. For ~2.5 days every agent was instructed to "read the file in full before
appending" while that read returned a hard refusal, and no written rule said what to do
instead — so each agent improvised a different partial read, and the safeguard read as
followed while being unexecutable. The prior drift (three entries putting `SCOPE-CHANGE`
in the `event` field) proves the same point from the other side: it happened while the
file was still readable, because "read it all" was never a reliable way to transmit a
convention buried in one of 182 entries.

**Correct alternative:** when a safeguard's mechanism has a physical limit, bound the
thing so the mechanism keeps working, state the convention explicitly instead of leaving
it to be inferred from precedent, and add a mechanical check that fails when the bound is
next crossed. A rule enforced only by an agent's eyes has no second line of defence. See
ISS-0119 and `lib/letflow/design/iss-0119-status-file-readability.md`.

## Presuming an in-progress artefact dead and writing that presumption into a handoff as fact (ORCH)

**WF03-ISS0119-20260821, Step 4c.** The TEST-RUNNER agent running the full suite was
stopped mid-step. ORCH went to salvage the leftover logs and found
`tmp-testrunner/main2.log` carrying a START line but no END line and no result line, and
concluded it had been killed mid-run. ORCH then wrote that conclusion into the
replacement agent's handoff **as fact**: "main2.log — INCOMPLETE, killed mid-run …
Treat as unusable; do not re-run it."

**It was not incomplete.** The run was still executing at the moment ORCH looked at it,
and it finished normally minutes later: `Finished in 530.2 seconds`, `Result: 1261/1274
passed`, `END 2026-08-21T08:41:34Z`. The replacement TEST-RUNNER re-checked the file
instead of accepting the briefing, recovered it, and thereby turned a 2-branch-runs-vs-1-
main-run comparison into 2-vs-2 — removing the sample asymmetry the briefing itself had
flagged as a limit, and materially strengthening the merge verdict. **That recovery is
the behaviour the whole validator design depends on, and it is why this entry exists
rather than a wrong verdict.**

**Why the usual defences miss it:**

* **An in-progress append-mode log and an abandoned one are byte-identical in shape.**
  Both lack the terminator. Absence of an end marker is evidence of "not finished
  *yet*", which is not the same proposition as "never will be". Nothing about the file
  distinguishes them; only the *writer's* liveness does, and that was never checked.
* **The observation laundered itself into an assertion by being written down.**
  `core-directives.md`'s Instruction Precedence puts a handoff's `task` block FIRST,
  above every protocol and directive. An agent that had simply believed ORCH would have
  been following the rules *correctly* — and would have produced a weaker verdict on
  three runs instead of four. A coordinator's guess acquires more authority than its
  evidence the moment it crosses a handoff boundary, and the receiving agent has no way
  to see how thin the basis was.
* **"Do not re-run it" closed the cheapest check.** The instruction did not merely state
  a belief; it pre-emptively forbade the one action that would have tested it.

**Correct alternative:**

* **Check liveness, never infer it from an artefact's shape.** Before declaring a
  process or its outputs dead: is the writing process still running, is the file still
  *growing* (compare size across a few seconds — one command), is there a lock or an
  open handle. A file that grew between two looks is not abandoned.
* **Mark environmental observations as observations, with their basis and their
  timestamp.** "As of 08:36 main2.log had no END line; I did not check whether the
  writer was still alive" is honest, costs nothing, and tells the receiving agent it may
  re-check. "INCOMPLETE, killed mid-run" tells it not to.
* **Never pair a shaky premise with a prohibition on testing it.** If the conclusion is
  uncertain, the derived instruction must leave the verification path open.

This is the same failure as **"Inheriting a claim from a record instead of re-deriving it
from the source"** above, with the record being a handoff and the author being the
coordinator — filed separately because the artefact here is a *live* one, and the
distinguishing test (does it grow?) is specific and cheap.

## A grep-shaped acceptance criterion can be tripped by the module's own moduledoc describing the invariant

**REQ-072, Step 2a (`lib/letflow/api/context.ex`).** AC1 required
`grep -rnE "Process\.(put|get)|:ets\." lib/letflow/api/` to return zero hits, as a
structural proof that `Letflow.Api.Context` never reaches into the raw process
dictionary or an ETS table for per-request state. ELIXIR-DEV needed the moduledoc to
*state* that same invariant in prose (readers need to know it was considered and
rejected, not just infer it from absence) — and a moduledoc sentence like "this module
never calls `Process.put/2`" contains the literal substring the AC's own grep pattern
is hunting for. Written naively, the file documenting compliance would have been the
one thing that failed the compliance check.

ELIXIR-DEV caught this before it became a false failure, and reworded the moduledoc
(`lib/letflow/api/context.ex`'s "No process dictionary, no ETS, anywhere in this
module" section) to describe the property without using the flagged call shape as a
literal substring — e.g. "no `Kernel` `put`/`get` pair on `self()`'s dictionary" and
"an `:ets` table" phrased so the pattern `Process\.(put|get)|:ets\.` does not match the
prose itself, while the sentence stays plain English rather than becoming garbled to
dodge the grep. REVIEWER (WF-02 Step 2d) verified both properties independently: the
grep genuinely returns zero hits, and the reworded prose reads as clear, ungarbled
English, not a regex-dodging contortion.

**Correct alternative:** when an acceptance criterion is phrased as a source-grep over
a directory, that grep will also scan the very file whose moduledoc documents
compliance with it — word the invariant's prose description so it doesn't reintroduce
the flagged substring (paraphrase the call shape, don't quote it), and verify the grep
against the final wording before treating the AC as satisfied, rather than assuming
"documented" and "not present" are independent facts about the same file.

**Recurrence: 2026-08-22, ISS-0227 (`WF03-ISS0227-20260822`) — same failure, different
medium, and the correct response inverts.** GH #465's acceptance criterion 4 was a
`git grep` for any remaining writer of two removed `Letflow.SandboxPool` fields
(`owner_pid:`, `op_schema_name`). Run unrestricted at branch HEAD `66c6898` it matches
**seven tracked files and zero lines of code**: both design documents
(`lib/letflow/design/iss0227-sandbox-pool-dead-field-removal.md`, and
`lib/letflow/design/iss0224-sandbox-pool-async-provisioning.md`, whose new section 17
names the fields in order to record their removal) plus five run handoff JSONs — a count
that only grows as the run commits further handoffs. Two of those media are ones the
entry above does not contemplate: `lib/` also contains `lib/letflow/design/*.md`, so a
`lib/`-scoped grep does not exclude prose, and `handoffs/**.json` quotes the removed
identifiers verbatim by necessity. (`docs/anti-patterns.md` is now a third: this entry
quotes both identifiers in order to document them.)

**The remedy above does not apply to them.** Rewording works for a moduledoc, whose
subject is the module and which merely *mentions* what it does not do. It does not work
when the matching text is the file's *subject*: a design document that cannot name the
field it removes is not a design, and a handoff is a frozen audit record that must not be
reworded at all. For those, **restrict the criterion by path or extension** instead:

```
git grep -nE "<pattern>" -- 'lib/**/*.ex' 'test/**/*.exs'
```

**Correct alternative (generalised).** When writing a grep-shaped acceptance criterion,
decide up front which of the two remedies applies: **reword** when the matching text is
*incidental* to the file's purpose; **restrict the path** when the matching text is *the
file's subject*. Then write the restriction into the criterion itself, so it is runnable
exactly as stated. A criterion that only passes once the verifier silently narrows it is
not a criterion — and the narrowing is the step that gets skipped, or done differently, by
the next agent.

## A migration version can collide with a test fixture's hardcoded version constant, not just another migration file

**Found:** 2026-08-22, ELIXIR-DEV, REQ-074 (`WF02-REQ074-20260822`). Two new tenant-scoped
migrations were added with versions `20_260_822_000_001`/`20_260_822_000_002`, registered
in `Letflow.TenantProvisioning.tenant_scoped_migrations/0` — a plausible-looking pair of
timestamps derived from the current date, same as every prior migration in this
codebase. `mix test` initially reported 1497/1506 passing; `test/letflow/api/context_test.exs`'s
own cross-tenant-404 test failed with `** (Postgrex.Error) ERROR 42P01 (undefined_table)
relation "tenant_....req072_probe" does not exist`.

Root cause: `test/letflow/api/context_test.exs` hardcodes
`@probe_migration_version 20_260_822_000_001` and replays it via an explicit
`TenantProvisioning.replay_migrations(tenant_id, [{@probe_migration_version,
ProbeMigration}])` call *after* `TenantFixture.provisioned_tenant!/1` has already run the
**real** manifest (which, with the new entry, now also records version
`20_260_822_000_001` — for a *different* module, `AlterGroupsAddDisplayNameDescription`).
`Ecto.Migrator` sees that version already present in `schema_migrations` for that tenant
schema and skips it as already-applied, so `ProbeMigration`'s `create table(:req072_probe,
...)` never runs — the probe table silently never gets created, and the test's own
`Repo.insert!` against it 42P01s. This is the exact "two independently-chosen migration
version numbers collide" class already documented above ("Two independently-merged Ecto
migrations picking the same version-number prefix"), but the *second* colliding side was
a hardcoded version constant inside a **test fixture module**, not another
`priv/repo/migrations/*.exs` file — so
`test/letflow/migration_filenames_test.exs`'s existing "no two migration files share a
version prefix" guard cannot catch it at all, since only one real migration file was
involved.

**Why this is easy to miss:** `grep -rn "20_260_822"` across `priv/repo/migrations/` alone
looks clean (only the new files' own version literals appear there), and `mix compile`
gives no signal either — the failure only shows up as a downstream `mix test` failure in
an entirely different, seemingly-unrelated test file, whose own diff was never touched by
this work.

**Correct alternative:** before picking a new tenant-scoped migration's version number,
also grep test fixtures/support files for the same literal, not only
`priv/repo/migrations/`: `grep -rn "20_260_822\|20260822" test/ lib/` (both the
underscored-integer and bare-digit forms — Elixir integer literals are commonly written
with `_` every three digits, and a hardcoded version constant in a test file may use
either form). If a collision is found against a test fixture's own version constant
(rather than another real migration), renumber the *new* migration to a value with no
collision anywhere (e.g. push the trailing digits further, `..000101`/`..000102` instead
of `..000001`/`..000002`) rather than touching the pre-existing test fixture's constant —
the fixture's version is that test's own load-bearing detail, not something to
renumber around a newcomer.

## A self-heal wired into `setup` that is not total over the states it can encounter

`test/letflow/identity_migration_test.exs`'s `with_only_this_tenant_visible!/2` (ISS-0060)
parks every *other* tenant's `public.tenant_schemas` row in a backup table for the duration
of one guarded assertion, and `restore_orphaned_guard_backup_rows!/0` (hardened by ISS-0111)
is the self-heal that puts them back on the next run if a prior run exited abnormally. Its
restore statement ended `ON CONFLICT (id) DO NOTHING` — which handles a duplicate **primary
key** and nothing else.

The state that actually occurred (ISS-0229) was a backup row whose **parent tenant no longer
existed**, so the restore raised `23503 foreign_key_violation`. Because the helper is called
from `setup`, that one unrestorable row failed **all 10 tests in the file, every run,
permanently** — and it could never clear itself, because the self-heal was the thing raising.

**Why this is wrong for this project specifically:** ISS-0060's design §6 open question 2 had
already considered a *unique-constraint* violation on this exact statement and knowingly
accepted "loud failure" for it. The **foreign-key** case was never considered in either that
design or ISS-0111's. So the gap was an omission wearing the clothes of an accepted
trade-off — the kind of thing a later reader skims past, because a nearby sentence looks
like it already reasoned about failure modes.

**Correct alternative:** a self-heal must be **total over the states the abnormal exit it
recovers from can leave** — enumerate them, and give each a terminal disposition (restore,
discard, quarantine). "Loud failure" is a legitimate disposition for ordinary code, but it
is *not* one for a recovery path: converting a recoverable condition into a permanent one is
the precise opposite of the job. Note also that the call site multiplies the obligation — a
self-heal invoked from `setup` fails every test in its file, so it carries a stricter
totality bar than one called from a single test body. When restoration is genuinely
impossible (the parent is gone, so the row is already meaningless), **discard the row with a
log naming it** rather than raising.

**Related trap, same family:** if the recovery path also *installs* the constraint that would
have prevented the bad state, heal first and constrain second. Adding the constraint while
the unrecoverable row is still present raises on the constraint's own validating scan and
bricks the file a second way.

## `elixirc --warnings-as-errors` is not a proxy for `mix compile --warnings-as-errors` — it gives the opposite answer

**Found:** 2026-08-22, CODE-DESIGNER, ISS-0227 (`WF03-ISS0227-20260822`), recorded as
W7/W8 and section 3.3 of
`lib/letflow/design/iss0227-sandbox-pool-dead-field-removal.md`. The design had to decide
whether deleting a private function's last call site would turn `op_schema_name/1` into a
red build, since this project's merge gate is `mix compile --warnings-as-errors`
(`docs/agents/protocols/GIT_MERGE.md:166`, and step 3 of `mix.exs`'s `letflow.check`
alias). The cheap way to check looks like running `elixirc --warnings-as-errors` on a
throwaway `.ex` file — no project, no deps, one second. **Measured both ways on the same
two-clause unused-`defp` shape: `elixirc --warnings-as-errors` prints the "is unused"
warning and exits 0; `mix compile --warnings-as-errors` prints the same warning and exits
1** ("Compilation failed due to warnings while using the --warnings-as-errors option").
The cheap probe answers the opposite of the gate that actually runs.

**Why this is easy to miss:** the two commands take the same flag name, emit the same
warning text, and differ only in the exit code — the one thing scrolled terminal output
does not show. An agent that eyeballs the warning and concludes "warnings-as-errors would
fail here" happens to be right for the wrong reason; one that does the more rigorous thing
and checks `$?` on the cheap probe concludes the opposite and is wrong. `mix compile`
applies the setting as a task-level failure over the whole compilation; `elixirc`'s flag
does not promote a file-level warning to a non-zero exit the same way.

**Correct alternative:** verify a mix-gate property with the mix gate. Create a throwaway
project with `mix new`, put the minimal reproducing shape in its `lib/`, run the **exact**
command the gate runs, and quote its exit code — never a nearer-to-hand single-file
compiler invocation that shares the flag name. The general rule this instantiates: **when
the claim is about what a gate does, the probe must be the gate's own command.** A smaller
tool that accepts the same flag is not a smaller version of the gate; it is a different
program, and the difference will be in the exit code rather than in anything printed.

## A side-finding's filing-time queue task outlives its own resolution when `queue_task_id:` was never recorded

**Found:** 2026-08-22, ORCH fork, ISS-0286's own conditional trigger ("investigate on a
third occurrence") — met by three cases in one session: queue task 22/ISS-0007
(filed 2026-08-15T17:04:52Z, resolved 2026-08-16T10:43:18Z as a side effect of
REQ-022 landing, not a dedicated fix run), task 70/ISS-0029 (filed
2026-08-17T05:15:45Z, resolved 2026-08-18T01:52:35Z via a dedicated
`WF03-ISS0029-20260818` run), task 165/ISS-0090 (filed 2026-08-19T20:22:38Z,
resolved — per its own backfilled record — 2026-08-20T00:00:00Z). All three sat
`open` and unlocked on `letflow-queue` for days after their underlying issue was
genuinely resolved, and each eventually resurfaced via ordinary `get_next_task`
polling as false claimable work, costing one fork dispatch + verification cycle
each time before the fork found nothing left to do.

**Root cause:** `TASK_QUEUE.md`'s `queue_task_id:` field on `docs/issues/<ISS>.yaml`
— the thing that lets a later resolving run `set_lock` the *exact* filing-time task
directly — was only added 2026-08-20 (`ISSUE_QUEUE.md`'s matching update, same
date). All three issues above were filed *before* that date and so were never
back-filled with it. Without a known `queue_task_id`, `TASK_QUEUE.md`'s own
documented fallback applies: exactly one `get_next_task` call, and if it doesn't
match this issue's `github_issue_number`, `release_lock` it back to `open` and
**do not chase further down the stack** — a deliberate rule (see the ISS-0092/GH#314
incident this same file documents elsewhere) that exists specifically to prevent an
agent from guessing at task ids and hitting an unrelated live task. The
side-effect is exactly this: a pre-2026-08-20 issue's original filing-time task has
no reliable path back to being released except waiting for `get_next_task`'s normal
FIFO-by-`impl_order` sequencing to surface it again on its own.

**This is not an ongoing defect.** Every issue filed on or after 2026-08-20 gets
`queue_task_id:` recorded at filing time (`ISSUE_QUEUE.md` step 2a), so a dedicated
resolving run for a *current* issue can `set_lock` the exact task directly per
`TASK_QUEUE.md`'s "Known `queue_task_id`" path — this class of staleness cannot
recur for issues filed after that date. It is a bounded, self-draining residue from
issues filed in the eleven days before the field existed: each stale task costs
one extra fork-verification cycle when it naturally resurfaces, then closes with no
code change, exactly as all three cases above did. **Do not react to a fourth
occurrence by re-deriving this root cause from scratch** — check the issue's
`discovered_at`/filing date against 2026-08-20 first; if it predates the field, this
is that same bounded residue, not a new defect. If a fourth occurrence names an
issue filed *after* 2026-08-20 (meaning `queue_task_id:` existed but still wasn't
used to release the original task), *that* would be a genuine regression worth a
fresh investigation.

**Not fixed by proactive bulk backfill:** `letflow-queue` deliberately exposes no
bulk-list/search-by-`github_issue_number` endpoint (see `TASK_QUEUE.md`'s "Design"
citation), so finding every pre-2026-08-20 stale task without a live claim in hand
would require exactly the kind of task-id guessing the "do not chase further" rule
exists to prevent. Letting the existing queue loop's `get_next_task` polling drain
them naturally is the correct, already-in-place remediation.
