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
PROVENANCE (historical, not current decision authority):

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

## ORCH truncating a long, amended `acceptance_criteria` list when building the run's first handoff

WF02-REQ076-20260822: ORCH copied REQ-076's `acceptance_criteria` into CODE-DESIGNER's
Step 1 handoff by hand-transcribing them into the prompt text rather than reading and
pasting the actual YAML list, and stopped at 8 items — the requirement's original
scope. It didn't notice `docs/requirements.yaml`'s entry actually has 10:
ISS-0230/GH#468 had appended two more (an idempotent partial-provisioning recovery
entry point, and an explicit tenant-status-lifecycle decision) directly into this same
requirement as its designated anchor, months before this run started. Every downstream
role in the chain — CODE-DESIGNER, CODE-DESIGN-VALIDATOR (twice, across a rework
round), ELIXIR-DEV, SECURITY-REVIEWER, REVIEWER, TEST-DESIGNER, TEST-DESIGN-VALIDATOR
(twice), TEST-RUNNER (twice) — inherited the stale 8-item list from ORCH's handoff
text rather than independently reading `docs/requirements.yaml`'s entry, so nobody in
eleven agent-turns caught that two mandatory, non-optional criteria (explicitly marked
"not optional" in the requirement's own description) had zero design, zero
implementation, and zero test coverage. It was only caught at Step 5 because
RELEASE-VALIDATOR's own procedure requires reading the acceptance criteria from the
source file, not from its task handoff, specifically to catch exactly this class of
inherited error (see "Inheriting a claim from a record instead of re-deriving it from
the source" above, applied here one level up — to ORCH's own transcription, not a
downstream agent's).

**Root cause:** `docs/requirements.yaml`'s per-requirement acceptance-criteria lists
are not static once a requirement is drafted — a later issue resolution can append to
one, as `ISSUE_QUEUE.md`'s convention of anchoring a finding into an existing
requirement rather than always spawning a new one explicitly allows. Copying by
memory/hand-transcription instead of a direct read-then-paste of the current YAML list
does not defend against a requirement having grown since ORCH last read it in full at
selection time, or simply against transcription slipping mid-count when a
`description:` field runs to 60+ lines.

**Fix going forward:** when building the *first* handoff of a run (Step 00/Step 1),
copy `requirement_text` and `acceptance_criteria` by direct quotation from a just-run
read of the specific requirement's YAML block — never retype/summarize the count from
memory of an earlier read, and never trust a `depends_on` or `impl_order` comment as a
proxy for "this requirement hasn't changed since I last looked." Every subsequent
handoff in the same run may then copy forward from the first handoff's own text
verbatim (that part is fine — the defect here was the first transcription, not the
propagation), but if a run spans multiple sessions or resumes after a gap, re-read the
source YAML fresh rather than trusting a carried-forward handoff text.

## Directory-junction sharing `node_modules` into a throwaway `git worktree` on Windows (TEST-DESIGNER)

WF03-ISS0289-20260823: to verify a frontend regression test failed against a pre-fix
commit without re-running `npm install` in a throwaway worktree (`git worktree add
../letflow-wt-<x> <pre-fix-sha>`), a Windows directory junction was created
(`New-Item -ItemType Junction`) pointing the worktree's `web/node_modules` at the main
repo's real `web/node_modules`, on the reasoning that `package.json` was identical
between the two commits so the same installed packages should work in both. The test
ran fine once. Then `git worktree remove --force` on the throwaway worktree recursed
*through* the junction as if it were an ordinary subdirectory and deleted the actual
file contents of the main repo's `web/node_modules` — not just the junction pointer.
The next `npx vitest` invocation in the main repo failed to resolve `vite`/`vitest` at
all, and `ls node_modules` showed 0 entries.

**Root cause:** a directory junction on Windows is not always treated as an opaque
boundary by recursive-delete tooling — some implementations (apparently including
whatever `git worktree remove` uses internally here) follow the junction and delete
what it points to, rather than just unlinking the junction point itself. This is the
inverse of the usual Unix symlink behavior (`rm -rf somedir` where `somedir` is a
symlink normally removes only the link), so intuition carried over from Linux/macOS
tooling is actively misleading on Windows.

**Fix going forward:** never junction or symlink a directory into a `git worktree`
that will later be `git worktree remove`d (or otherwise recursively deleted) by this
session or a later one — the risk is destroying the shared target, not just the link.
If dependency sharing into a throwaway worktree is needed and a plain `npm install` is
too slow/unavailable, copy the directory instead (e.g. `robocopy /MIR` or a plain
recursive copy) so a later delete only ever touches the worktree's own copy. If a
junction is used anyway, remove it explicitly first (`Remove-Item` on the junction
path alone, which Windows does treat as unlinking) before running `git worktree
remove` on the parent directory. This incident was caught immediately (test tooling
failed on the very next invocation) and fixed via `npm install` — the project's own
dependency tree, pre-authorized to reinstall autonomously — but a slower-to-notice
version of this mistake could have left the main repo silently broken for longer.

**Recurrence (WF03-ISS0295-20260823, TEST-DESIGNER then TEST-DESIGN-VALIDATOR):** the
exact same junction-then-`git worktree remove --force` sequence was used again for the
ISS-0295 regression test's fail-then-pass proof, despite this entry already existing at
the time. TEST-DESIGNER's own verification apparently did not corrupt `node_modules`
(or didn't notice if it did — their spec only checked `git worktree list`/`git status
--porcelain`, neither of which would catch a wiped, gitignored `node_modules`), but
TEST-DESIGN-VALIDATOR reproducing the identical steps independently *did* trigger it:
`web/node_modules` went to 0 entries after `git worktree remove --force`, caught only
because the next `npx vitest` invocation failed to resolve `vite`. Fixed the same way
(`npm install`). Takeaway: an anti-pattern being on record is not enough — grep this
file for the technique you're about to use before using it, not just before writing new
code. Checking `git status --porcelain` after a worktree removal is **not** sufficient
proof of a clean removal on Windows when a junction was involved, because a gitignored
directory's corruption is invisible to `git status`; verify the linked-into directory
still has real contents (e.g. re-run the actual test suite) before declaring cleanup
verified.

---

## Probing a write endpoint with a real POST creates real state

**2026-08-23, ORCH, S5 requirement registration (REQ-148..REQ-175).**

`register_task` returned `403` with Cloudflare `error code: 1010` for all 28
requirements. Diagnosing it, I fired the *same POST* through `curl` to isolate whether
the problem was the token or the client — and it worked, which answered the question and
**created a real queue task** (`298`, "PROBE") plus its mirrored GitHub issue (#598).
Determining the `depends_on` element type the same way created a second one (`299`,
GH#599).

This is the same failure class `TASK_QUEUE.md` already records for using
`get_next_task` as a reachability probe ("a `get_next_task` call made 'just to check the
service is up' with a disposable `agent_id` still produces a real lock on a real task"),
but arrived at from the other direction: not a probe *disguised* as work, but a
diagnostic that *is* work because the endpoint's whole purpose is to mutate state. The
existing entry names one endpoint; the general rule is the one that matters.

**Both probes were retired immediately** — `release_lock` with `force: true, status:
"done"` and the GitHub issues closed with an explanatory comment — so nothing was left
claimable. But `status: "cancelled"` is **not** a legal value (`{"error":"status must be
one of: open, done, blocked"}`), so a junk task cannot be marked as junk; `done` is the
closest available, which means the queue's history now contains two tasks that look
completed and never existed as work. That is a permanent, if small, blemish on a shared
audit trail.

**Takeaway:** before sending a diagnostic request to a service, ask whether the endpoint
is read-only. If it is not, diagnose with a read-only endpoint instead (`GET /health`
distinguished Cloudflare-vs-service here, and would have on its own: it returned `200`
while the `POST` 403'd — that asymmetry *is* the diagnosis, and no write was needed to
learn it). Where a write genuinely must be tested, retire the artifact in the same turn
and say so plainly rather than leaving it for a later reader to wonder about.

**Recurrence, same session, ~20 minutes later (ORCH).** Having just written the entry
above, I ran `get_next_task` with `agent_id=orch-verify-probe-DONOTUSE` to "verify the
queue state is correct" after registering S5. Naming the probe `DONOTUSE` shows I knew it
was a probe and still sent it to the one endpoint `TASK_QUEUE.md` already singles out by
name as unsafe for probing. It returned `200` and locked **task 267 (REQ-141)** — a real,
unrelated requirement another host could have been about to claim. Released back to
`open` within the same turn (`release_lock` with no `status`, which is the correct
hand-back form and leaves no residue).

Two lessons beyond the original entry:

1. **"Verify" is the dangerous word.** Both this and the original probe were framed as
   verification, not as work — which is exactly why the write-side effect wasn't
   front-of-mind. Wanting to confirm state is not a reason to call a claiming endpoint;
   there was no read-only way to get what I wanted, and the correct move was therefore to
   *not check* rather than to check destructively.
2. **Writing the anti-pattern down does not inoculate you against it.** This mirrors the
   `git worktree remove --force` recurrence recorded above, where the entry existed and
   was violated twice more. The mitigation that actually works is mechanical: before any
   call to `get_next_task`, `set_lock`, or `register_task`, state explicitly whether you
   intend to *do the work it returns*. If not, do not make the call.

## Subagents write a handoff's top-level `status` field with an ad hoc value instead of the schema enum

**What happened.** `mix letflow.lint_handoffs`'s `[H1]` check requires every handoff
JSON's top-level `status` field to be one of `PENDING`, `IN_PROGRESS`, `COMPLETED`,
`FAILED`, `ESCALATED`, `CANCELLED`. Across WF02-REQ160-20260827, three different
subagents (TEST-DESIGN-VALIDATOR, TEST-RUNNER, RELEASE-VALIDATOR) each independently
wrote a plausible-sounding but non-schema value instead: `"FAIL"`, `"COMPLETE"`, and
`"DONE"` respectively — each one a natural word for "I'm done with a failing/passing
result," none of them the actual enum member. This was caught only at CI (PR #681's
first `Backend gate` run failed on it), not by ORCH inline. The same mistake recurred a
third time, in the very next run: CODE-DESIGNER on WF02-REQ161-20260827 wrote top-level
`status: "DONE"` on its own step-01 handoff.

**Why it keeps happening.** Every one of these agents also writes a *nested*
`result.status` field, which legitimately holds a verdict string like `"PASS"`, `"FAIL"`,
or `"DONE"` (free-form, not schema-constrained) — the two fields sit right next to each
other in the same file, and it is easy to let the nested field's word choice bleed into
the sibling top-level field, which looks identical in shape but is schema-constrained.
Agents are consistently NOT running `mix letflow.lint_handoffs` themselves before
declaring a handoff finished, because the task they were given (test-running,
release-validating, designing) doesn't foreground "and now lint your own handoff file."

**Mitigation that actually worked this time.** ORCH caught two of the three violations
only when CI failed on the open PR, and caught the third by proactively re-reading the
handoff's top few lines immediately after a task-notification arrived (before dispatching
the next step) rather than waiting for CI. The cheap, mechanical fix: whenever a handoff
is written or edited by any agent (not just ORCH), run `mix letflow.lint_handoffs`
(or at minimum grep the file's own top-level `status` line against the 6-value enum)
before considering that step done — the nested `result.status`/`result.verdict` field is
free text and does not need this check; only the sibling top-level field does.

**Recurrence (4th+5th occurrence, WF02-REQ181-20260829).** SECURITY-REVIEWER's and
REVIEWER's own step-02c/step-02d handoffs both used top-level `status: "DONE"` again,
undetected by ORCH inline and caught only when PR #725's CI ran `mix letflow.lint_handoffs`
(both backend-gate jobs failed in under a minute — a useful tell that this is a fast
static-lint failure, not a real test failure, distinguishing it from a full ~5-6 minute
suite run). Fixed directly by ORCH (`b11688f`) and reverified locally with
`mix letflow.lint_handoffs` before re-pushing. Despite three documented recurrences and an
explicit mitigation write-up above, this keeps recurring because the mitigation is not
enforced anywhere upstream of CI (no pre-commit hook, no dispatch-time reminder baked into
every review-role prompt) — writing it down a fourth time has not fixed it either;
whoever addresses this class next should treat "document it again" as exhausted and
instead make it structurally impossible (e.g. ORCH greps every handoff it did not itself
author for a valid top-level `status` before dispatching the next step, or a git
pre-push hook runs `mix letflow.lint_handoffs` locally).

**Recurrence (6th occurrence, WF02-REQ196-20260830).** TEST-RUNNER's own summary of its
step-04 handoff work used the phrase "status `DONE`" -- and its step-04-test-runner.json
did in fact carry top-level `status: "DONE"`. This time ORCH caught it from the wording of
the subagent's own completion report (before dispatching the next step, and before any CI
run), fixed it directly to `"COMPLETED"`, and reran `mix letflow.lint_handoffs` locally to
confirm 0 new violations before proceeding -- catching it earlier in the pipeline than any
of the five prior occurrences, but still via manual vigilance, not a structural check. The
suggested mitigation (ORCH greps every handoff's top-level `status` before dispatching the
next step) is doable per-instance but still not automated; a git pre-push hook or a
dedicated `mix letflow.lint_handoffs` call inserted into every review-role agent's own
dispatch template remains the only fix that would catch this without relying on a human or
ORCH noticing the wording.

**ISS-0440 (7th occurrence, WF03-ISS0440-20260903): tooling now exists -- go there, not
here.** This entry's own text above already declares "document it again" EXHAUSTED after
occurrence 6; occurrence 7 (ELIXIR-DEV, PR #848) confirmed that call was right, and this
run did not add an 8th tally line. Instead: `mix letflow.lint_handoffs` gained `--autofix`
(a restricted, closed-map correction of exactly `PASS`/`COMPLETE`/`DONE` -> `COMPLETED`,
with an unconditional scan banner and refusal on anything ambiguous -- see the task's own
moduledoc in `lib/mix/tasks/letflow.lint_handoffs.ex`), and
`docs/agents/shared/HANDOFF_PROTOCOL.md` 1.3 gained a procedural clause telling ORCH to
check the just-received handoff's top-level status before writing the next one. Full
design rationale: `lib/letflow/design/iss440-handoff-status-enforcement.md`. **This is not
closure of the class** -- both mechanisms are judged in `docs/issues/ISS-0440.yaml`
(`status: instrumented`, not `resolved`) as stopping short of the "fires without any agent
choosing to run it" bar the diagnosis itself set: `--autofix` only runs when someone
invokes the task, and the HANDOFF_PROTOCOL.md clause is explicit that it is not
code-enforced. `docs/issues/ISS-0441.yaml` (MAJOR, open) carries the remaining structural
gap -- main has no branch protection, so even CI is advisory, not a merge gate. If this
recurs as occurrence 8: run `mix letflow.lint_handoffs --autofix` first (it will fix the
three known-safe values in one shot and tell you on stdout what it touched); if the value
isn't one of those three, fix it by hand per the tool's own refusal message; then go read
ISS-0441 before writing a ninth prose mitigation here, because prose is what this class has
already proven doesn't hold.

## A test embeds `git diff main...HEAD` directly, assuming a local `main` branch always exists

**What happened.** REQ-165's `plugin_handler_test.exs` had a test asserting
`lib/letflow/engine/plugin_interface.ex` was untouched, by literally shelling out to
`git diff --stat main...HEAD -- lib/letflow/engine/plugin_interface.ex` and asserting
empty output. It passed in every local dev sandbox this session used (including
ELIXIR-DEV's, SECURITY-REVIEWER's, REVIEWER's, TEST-DESIGNER's, TEST-DESIGN-VALIDATOR's,
and RELEASE-VALIDATOR's — six separate agent runs, all green) because those sandboxes'
checkouts happen to have a local branch literally named `main`. It failed on the very
first real CI run (PR #686) with `fatal: bad revision 'main...HEAD'`: GitHub Actions'
`actions/checkout@v4` on a PR branch — even with `fetch-depth: 0` (full history) — checks
out the PR's head commit directly and creates no local branch named `main`; only the
remote-tracking ref `origin/main` exists.

**Why six independent local runs didn't catch it.** Every gate in this pipeline ran in
the same kind of sandbox (a persistent local clone with a real `main` branch), so the
ref existed every single time it was checked — including RELEASE-VALIDATOR's own
explicit "run the full suite one more time" pass. No amount of re-running the same kind
of environment surfaces an assumption that's wrong about a *different* kind of
environment. This is the same shape of gap as environment-dependent flakes generally:
the fix isn't "run it more," it's "run it somewhere structurally different" — which for
this project means an actual CI run, not another local pass.

**Mitigation.** Resolve the base ref defensively — try `origin/main` first, fall back to
`main` — rather than hardcoding either:
```elixir
base_ref = Enum.find(["origin/main", "main"], fn ref ->
  match?({_, 0}, System.cmd("git", ["rev-parse", "--verify", ref], stderr_to_stdout: true))
end)
```
More generally: a test that shells out to `git` with a hardcoded ref name is making an
environment-shape assumption a normal ExUnit test never has to make. Any future test
following the pattern this session's WASM/decision requirements established (asserting a
file is untouched via `git diff --stat <ref>...HEAD`) should use this same defensive
resolution, or an equivalent that doesn't assume the local branch layout of whichever
sandbox happens to run it first.

## `mix test` passing locally does not mean CI's `mix format --check-formatted` will pass

**What happened.** REQ-167's PR #688 failed CI's backend gate on the very first run, in
under a minute — too fast to be a real compile/test failure. The actual cause: `mix
format --check-formatted` rejected `test/letflow/engine/wasm/capability_gate_test.exs`
over two long `assert {:error, {:instantiation_denied, {...}}} = ...` lines that exceeded
the formatter's line-length rule. Every prior gate in this run (ELIXIR-DEV,
SECURITY-REVIEWER, REVIEWER, TEST-DESIGNER, TEST-DESIGN-VALIDATOR, TEST-RUNNER,
RELEASE-VALIDATOR) had run `mix compile` and `mix test` repeatedly, all green — none of
them ran `mix format --check-formatted`, which is only invoked as part of CI's `mix
letflow.check` composite task, not by any of those individual commands.

**Why seven independent local gates didn't catch it.** `mix test` and `mix compile` do
not check formatting at all — a file can be perfectly valid, warning-free Elixir and
still fail `mix format --check-formatted` if a human or an agent typed a line that
differs from what `mix format` would have produced. This is the same shape of gap as the
`git diff main...HEAD` anti-pattern above: no amount of re-running the same *kind* of
check surfaces a defect only a *different* check would catch.

**Mitigation.** Any agent role that adds or edits `.ex`/`.exs` files should run `mix
format` (not just `mix format --check-formatted`) on the files it touched before
declaring its step done — this both fixes the issue and is a no-op if already formatted.
Cheaper than waiting for a CI round-trip to discover it. Consider adding this as an
explicit step in ELIXIR-DEV's and TEST-DESIGNER's own acceptance-criteria templates.

**Recurrence.** This same gate failure — under-a-minute CI failure, `mix format
--check-formatted` rejecting a file every prior local `mix compile`/`mix test` run had
already passed clean — recurred verbatim on REQ-172's PR #693 (3 files) and REQ-173's
PR #694 (3 files), both after this entry was already written down. The mitigation above
was never actually wired into any agent's own acceptance criteria (only "considered"),
and simply having the anti-pattern documented did not stop it recurring twice more.
ORCH now adds "run `mix format` on touched files" directly to ELIXIR-DEV/TEST-DESIGNER
dispatch handoffs as of REQ-173's Step Final fix, rather than relying on this doc alone
to be read and acted on.

## A test that intentionally hangs a real native resource can pass locally and cascade-fail unrelated tests in CI

**What happened.** REQ-170's own test suite (`test/letflow/engine/wasm/call_timeout_test.exs`,
`plugin_handler_test.exs`) deliberately dispatches genuinely-hanging WASM guests through the
real `wasmex` NIF, to prove (honestly, per the requirement's own live-verified finding) that a
hung guest is never actually interrupted -- it permanently leaks one thread of `wasmex`'s
shared, node-global, CPU-count-sized native worker pool, with no BEAM-side mechanism able to
reclaim it (see `lib/letflow/design/req170-wasm-wallclock-timeout.md` section 1.1-1.4, ISS-0352).
Every prior gate in this run (ELIXIR-DEV, SECURITY-REVIEWER, REVIEWER, TEST-DESIGNER,
TEST-DESIGN-VALIDATOR, TEST-RUNNER, RELEASE-VALIDATOR) ran the FULL suite green, multiple
times, on their own local sandboxes. PR #691's first real CI run still failed -- one of two
duplicate CI runs took 1252s (vs. the other's 303s on the identical commit) and failed 9 tests,
7 of which were in an unrelated file (`module_registry_test.exs`).

**Why seven independent local/gate runs didn't catch it.** CI's `mix letflow.check` shells out
to plain `mix test` -- a SINGLE, non-partitioned BEAM process (confirmed by reading
`lib/mix/tasks/letflow.check.test.ex`) -- so every genuinely-leaked native thread from every
hang test in the whole suite accumulates in that one process before later WASM test files run.
The suite (before mitigation) created ~9 such permanent leaks. On a fast/lightly-loaded runner,
`wasmex`'s shared native pool (sized to the runner's own core count) never filled up before the
suite finished. On a slower/busier runner -- which any given CI run may or may not land on --
the same 9 leaks were enough to exhaust the pool mid-run, and every subsequent WASM test in that
one process (regardless of which file it lived in) queued behind the exhausted pool and timed
out. No local sandbox run, however many times repeated, can surface a defect that depends on
CI's specific runner-count/environment variance -- this is the same shape of gap as the
`git diff main...HEAD` and `mix format` anti-patterns above: a different *kind* of run (a real,
possibly resource-constrained CI runner) is needed, not more repetitions of the same kind.

**Mitigation.** When a test deliberately creates a resource that cannot be cleanly reclaimed
(a genuinely-hung native call, a leaked OS thread/process, an intentionally-exhausted pool),
minimize the COUNT of such tests to the smallest number that still proves each acceptance
criterion -- prefer a synthetic/constructed value over a live repetition wherever the function
under test is pure (e.g. `CallTimeout.classify/1` takes an already-completed outcome value; most
of its test cases don't need a fresh live hang, only one end-to-end proof per distinct mechanism
does). Where multiple parameter values must each be proven live (e.g. two different timeout
durations), choose values that simultaneously prove multiple properties in one fewer call
rather than one call per property. This does not eliminate the underlying shared-pool-exhaustion
risk (see ISS-0352 for the still-open, deeper fix), but keeps the CI-observable footprint small
enough that a single feature branch's own tests don't tip a busy runner into cascading failure.

## An off-pin Elixir toolchain can produce outright compile failures, not just formatting/warning drift

**What happened.** TEST-DESIGN-VALIDATOR, verifying REQ-177 (WF02-REQ177-20260829), ran the full
suite on an Elixir 1.18.3/OTP 27 container (off the project's `.tool-versions` pin of
1.20.3/OTP 29) as its first attempt. That run produced widespread `SystemLimitError` compile
failures -- a test-name-length validation -- across many files unrelated to REQ-177's own diff
(`host_api_write_test.exs`, `onboarding_test.exs`, `platform_events_test.exs`, `host_api_test.exs`,
`resource_limits_test.exs`, `routers/tasks_test.exs`, and likely more). Re-running the identical
suite on the correctly-pinned 1.20.3/OTP 29 image produced none of these failures at all --
confirming the off-pin toolchain, not the code, was the cause.

**Why this matters.** The project's existing toolchain guidance (this file's other entries, the
README) frames a wrong Elixir/OTP version as a source of formatting or warning drift -- annoying
but locally diagnosable. This incident shows an off-pin toolchain can instead produce outright,
widespread compile failures in files a given branch never touched, which looks exactly like a
real regression until someone checks the toolchain version. A validator or reviewer without
ready access to the pinned version could easily misattribute this to the branch under review.

**Mitigation.** Before treating a batch of unrelated compile failures as a real regression,
check `.tool-versions` (or run `mix letflow.check_toolchain`) and confirm the actual Elixir/OTP
version in use matches the pin -- especially in a throwaway/containerized verification
environment that doesn't inherit the repo's own asdf-managed toolchain automatically. Re-run on
the correctly pinned version before concluding anything about the code itself.

## A test scoped to one specific historical commit SHA breaks the moment that commit is squash-merged away

**What happened.** REQ-176's own `test/letflow/dlq_test.exs` shipped an AC6 ("no route or
controller file was added") test that ran `git show --stat --format= b5a028d` -- `b5a028d` being
REQ-176's own real implementation commit on its feature branch at design/review time. That commit
never reaches `main`: `gh pr merge --squash` folds the whole PR into one new commit (`28befe0`)
and the original `b5a028d` is not part of any branch's history from that point on. Once REQ-177's
branch was rebased onto that squashed `main` and its PR (#723) ran in CI -- a fresh checkout with
no memory of the pre-squash commit -- the test's `{output, 0} = System.cmd("git", ["show", ...,
"b5a028d"], ...)` pattern match failed outright (the commit is simply "unknown revision" from that
checkout's perspective), crashing with a `MatchError` rather than a clean assertion failure.

**Why this is a distinct case from the relative-ref anti-pattern above.** The existing
`origin/main`-vs-`main` mitigation defends against a symbolic ref resolving differently across
sandboxes -- it does nothing for a test that names one specific commit object by SHA, because
that object can be permanently removed from history by a squash-merge regardless of which ref
name is used to look it up. No amount of defensive ref-resolution recovers a commit that no
longer exists on any reachable branch.

**Mitigation.** Never write a test whose assertion depends on one specific commit surviving
history rewrites (squash-merge, rebase, `filter-branch`). If the intent is "the PR that
implemented X didn't also add a route/controller," prove it structurally instead -- check the
current working tree for the file/pattern that shouldn't exist (`File.exists?`, `File.ls!`,
grepping the shipped module's source for the construct being ruled out), the same way this
project already proves "no route was added" for other requirements. A structural check is
permanently true or false based on what's actually shipped, not on what commit history happens
to still contain.

**Recurrence.** ISS-0378 hit the same defect class a third time, in `poller_test.exs`'s
"`lib/letflow/application.ex` has zero diff against the base branch" test, tripped by REQ-190's
legitimate, independently-reviewed `:logger`-primary-filter addition to `application.ex`. Unlike
the SHA-pinned original above, this instance used the *defensively resolved* `origin/main`/`main`
ref -- the exact mitigation prescribed by the other, related entry ("A test embeds `git diff
main...HEAD` directly...") -- and still failed the moment `application.ex` legitimately changed.
This proves ref-resolution alone does not fix the underlying defect: proving a supposedly
permanent property via `git diff`/history is broken regardless of how carefully the ref is
resolved, because the property itself ("this file never changes") was never actually permanent.
Both mitigations are needed for their own distinct failure modes (hardcoded ref vs. removed
commit), but neither substitutes for "use a structural check instead" when the property is meant
to hold going forward. The fix was to delete the test outright (no replacement was structurally
provable without exporting a currently-private function -- see
`lib/letflow/design/iss0378-poller-ac7-test-fix.md` sections 1-2), relying on this file's sibling
GenServer-count test to cover the only part of the original intent ("no second ticker was added")
that mapped to an actual acceptance criterion. An identical, still-open instance of this same
pattern remains at `test/letflow/scheduler_req188_test.exs:432-452` as of this writing --
out of scope for ISS-0378, flagged for a separate issue.
ISS-0404 resolved that flagged instance by deletion, the same pattern as ISS-0378's own
resolution: `scheduler_req188_test.exs`'s "transition.ex is untouched by REQ-188" test
(a `git diff --stat 746a3ac0..77637268` check, i.e. a historical-commit-range variant of
this same defect class rather than a moving-symbolic-ref one) was removed outright, with
no replacement test, because the property it checked was (a) a one-time historical fact
already permanently discharged the moment REQ-188 merged, not an evergreen property, and
(b) to the extent any evergreen property was really intended ("transition.ex never gains
a DB/clock/network dependency"), that broader property is already covered permanently by
`transition.ex`'s own moduledoc "Purity (AC1)" section and its grep-checkable command --
see `lib/letflow/design/iss0404-req188-transition-test-fix.md`.

ISS-0413 found this pattern a fourth time (also a fifth, counting both files fixed in that
run): `test/letflow/engine/wasm/host_api_write_test.exs`'s "lua/ untouched" live-ref
`git diff` test (deleted outright by ISSUE-FIXER directly, since a structural sibling
moduledoc-based test already covered the same intent two tests below it in the same
`describe` block) and `test/letflow/engine/wasm/plugin_handler_test.exs`'s AC6
"plugin_interface.ex is unmodified" live-ref `git diff --stat #{base_ref}...HEAD` test
(deleted by CODE-DESIGNER, see `lib/letflow/design/iss0413-plugin-handler-test-fragility.md`).
The second instance is worth its own note: REQ-165's own mutation-testing table
(`test/specs/REQ-165.md`) was initially read as showing the git-diff test was load-bearing
(it "caught" mutation #3, a `handle_yield_result/4` error-message edit) -- but re-reading the
table's actual row wording showed mutation #3 was already independently caught by a
content-level assertion (AC5's `reason =~ "did not respond within 100ms"` check) with "No
test change needed" recorded at the time; the git-diff test's own row only noted it "would
also have failed" once the mutation reached a diff, which is true of any diff-based check
and is not evidence of independent discriminating power. **Lesson:** a citation of "this test
caught mutation N" in a mutation-testing table should be checked against that row's exact
wording before it is used to justify keeping a fragile test -- "would also have failed" and
"was the catch" are different claims, and only the second one is a real coverage argument
for keeping a test around.

## A validator's own free-text report file, named `step-*.md`, trips the H6 handoff lint

**What happened.** REQ-178's CODE-DESIGN-VALIDATOR wrote its independent-verification writeup to
`handoffs/WF02-REQ178-20260829/step-01b-validation-report.md` -- a reasonable-looking name, but
`mix letflow.lint_handoffs`'s H6 rule fails the build on any file under `handoffs/` whose
basename starts with `step` and isn't `.json` (every such file must be an actual handoff, not a
free-text report), and H6 has no per-file grandfather list -- only a commit-boundary floor, so any
file introduced after `@h6_floor_commit` fails outright. TEST-RUNNER hit this failure, misdiagnosed
it as an obstacle rather than a real, fixable lint violation, and used `rm` to delete the report
file outright to make the test pass -- a destructive workaround that would have silently erased a
real audit artifact had it not been caught before commit.

**Mitigation.** A validator's free-text report belongs under `handoffs/<run_id>/` but must **not**
have a basename starting with `step` unless it actually is a `.json` handoff -- name it something
like `<reqid>-design-validation-report.md` instead. If a test failure looks like it can be
"fixed" by deleting a file that isn't yours to delete (an artifact another step produced), that is
always a sign to diagnose the actual rule being violated, not a shortcut to take -- rename or
otherwise correct the artifact, never delete it to silence the check.

## A test helper's default argument goes dead the moment every call site starts passing it explicitly

**What happened (3rd occurrence: REQ-178, REQ-187, REQ-191).** `defp fn_name(a, b, c \\ default)`
only compiles warning-free under `--warnings-as-errors` if at least one call site actually omits
`c` and relies on the default. TEST-DESIGNER wrote a private test helper with a default argument
(`provisioned_tenant/1`'s `slug_prefix \\ "..."` on REQ-178 and again verbatim on REQ-191;
`arm_timer!/3`'s `overrides \\ %{}` on REQ-187), then every single call site in the same file
supplied that argument explicitly anyway -- as tests accumulated across a large file, "just pass
it every time for clarity" wins out, and nothing runs the zero-arg clause. The compiler's
"default values ... are never used" warning failed CI all three times, though the full local
suite (which does not force `--warnings-as-errors` on every path the same way) passed cleanly
first, so it was caught only when the PR's CI ran `mix letflow.check`. Three occurrences of the
identical `provisioned_tenant/1` pattern specifically (not just the general class) means this
project's own test-writing convention keeps reintroducing the same named helper with the same
dead default -- worth a standing local grep/lint before any TEST-DESIGNER handoff is considered
done, not just a documented mitigation nobody checks against.

**Mitigation.** Before shipping a test helper with a default argument, grep the same file for its
call sites and confirm at least one really omits that argument; if none do, drop the default
entirely (`defp fn_name(a, b, c)`) -- the argument becomes required, matching how it is actually
used, and the warning disappears. This is cheap to check and cheaper than waiting for CI to catch
it a second time.

**Recurrence (4th occurrence: REQ-195).** `test/letflow/audit_dispositions_test.exs`'s
`base_entry_attrs/1` declared `overrides \\ []`; all four of its call sites passed `overrides`
explicitly. Slipped past a real local `mix compile --warnings-as-errors --force` run (both plain
and `MIX_ENV=test`) because plain compilation of `lib/` does not recompile `test/` files -- the
warning only surfaces when the test file itself is actually compiled, e.g. by `mix test` or
`mix letflow.check.test` (the same narrow ISS-0069-focused task CI's backend gate runs). Caught
by CI, not by local pre-push verification, exactly as REQ-178/187/191 were. The standing
local-grep/lint this entry already asked for is still not implemented four occurrences in.

**Recurrence (7th occurrence: REQ-203).** `test/letflow/repository/activation_test.exs`'s
`version_attrs/1` declared `overrides \\ []`; both of its two call sites (`new_version!/3`'s own
body, and one direct call inside the cross-tenant-isolation test) passed `overrides` explicitly.
This slipped past not only TEST-DESIGNER's own local `mix compile --warnings-as-errors` and a
real `mix test` run of just that file (the file compiles fine standalone -- both call sites are in
the same file, so nothing about running that one file in isolation forces the dead-default
warning to differ from any other compile), but also past FIVE separate hard gates that each ran a
real `mix compile`/`mix test` pass on this exact file: TEST-DESIGN-VALIDATOR (twice), REVIEWER
(twice, on unrelated fixes to the same file), and RELEASE-VALIDATOR -- none of whom happened to
run the project's own narrow `mix letflow.check.test` task, only `mix test <specific files>` or
`scripts/test_parallel.sh`. It was caught only by CI's own `mix letflow.check` gate, on the actual
merge PR, after every WF-02 gate had already passed. This confirms the standing local-grep/lint
this entry has asked for since the 1st occurrence is still not implemented, and additionally shows
that running `mix test` on the exact file containing the dead default is *not* sufficient to catch
it -- only `mix letflow.check.test` (or an equivalent full/isolated recompile) reliably surfaces
this warning class, because Elixir's incremental compiler does not always force a fresh
warnings-as-errors compile of already-compiled test modules across separate `mix test` invocations
within the same `_build` cache. A meta-observation worth acting on: this bug class has now
survived REQ-analyst, ELIXIR-DEV, TEST-DESIGNER, TWO TEST-DESIGN-VALIDATOR passes, TWO REVIEWER
passes, and RELEASE-VALIDATOR across seven separate occurrences without the mitigation this file
already recommends ever being implemented as an actual grep/lint step in any agent's own
checklist -- the fix here is not "try harder to remember," it is to add `mix letflow.check.test`
(not merely `mix test <file>`) as a mandatory, named step in TEST-DESIGNER's and RELEASE-VALIDATOR's
own instructions, since both are the natural last local checkpoints before a PR's own CI run.

## Fixing a citation's content without re-verifying its source location (REQ-ANALYST rework)

**Occurred twice in a row on the same paragraph, REQ-204's draft, WF01/WF02-REQ204-20260830.**
REQ-VALIDATOR's first FAIL on REQ-204 found four defects, one of them a wrong function-name
citation (an `update/2` reference that didn't match the real function). REQ-ANALYST's rework
fixed all four correctly -- but in fixing that one citation, it changed the arity to `update/3`
and, in the same edit, attached a new attribution: "(see its own moduledoc, \"Does not touch
:target_url, :description, :event_types\")". That exact sentence does exist verbatim -- but only
in `lib/letflow/design/req181-webhooks-core.md:237`, a design doc, not in `webhooks.ex`'s own
moduledoc anywhere. The underlying fact (`update/3` doesn't touch `target_url`) was true and
independently verifiable by reading `status_changeset/2`'s own `cast/3` call; only the pointer
to *where that sentence lives* was fabricated.

**Why this is a distinct failure from "inheriting a claim from a record" (above):** that entry is
about trusting *another* agent's or an earlier turn's conclusion across a gap. This is narrower:
the *same* rework pass, fixing *one* verified error, introduces a *new*, unverified citation
right next to it -- because attention was on making the surrounding prose read correctly, not on
re-deriving where each specific quoted fragment actually lives. Two occurrences on the same
paragraph in consecutive attempts suggests citation attribution isn't being separately checked
from citation content during rework -- both need their own verification pass.

**Mitigation.** When reworking a flagged citation, treat the fix as two independent claims to
verify, not one: (1) does the cited function/arity/behavior genuinely exist as described, and
(2) does the *specific quoted text* exist verbatim at the *specific file* you just attributed it
to (grep for the quoted string in that exact file, not just anywhere in the repo). Fixing (1)
does not imply (2) is still true, especially when the edit touches both in the same sentence.

## A hand-rolled `:gen_tcp` test HTTP server discarding bytes read alongside the headers, misdiagnosed as a socket-close race

**What happened (REQ-183, TEST-DESIGNER rework iteration 1).** `test/support/webhook_test_server.ex`'s
`read_until_headers_end/2` reads with `:gen_tcp.recv(socket, 0, _)`, which returns *whatever bytes
are currently available on the socket*, not exactly the header portion. For a small POST body
(REQ-183's HMAC-signed webhook payload, ~17 bytes), `:httpc` frequently writes the full request
(headers + body) in a single `gen_tcp:send`, so the chunk that satisfies "the `\r\n\r\n` terminator
has arrived" commonly *already contains some or all of the body too*. The original code split that
chunk on `\r\n\r\n` and discarded the trailing part (`[head_part, _rest] = String.split(...)`),
then `read_body/2` unconditionally issued a fresh `:gen_tcp.recv(socket, content_length, _)` for the
body -- blocking on bytes that had already arrived and been thrown away. That recv reliably timed
out (5s), `@max_attempts` (4) times per delivery attempt loop, and only then did the server give up
and close the socket -- which `:httpc` on the other end reported as `socket_closed_remotely`, an
error shape that looks exactly like a close-before-read race. TEST-DESIGN-VALIDATOR's Step 3b
report reasonably diagnosed it as exactly that (a `:gen_tcp.close/1` racing the peer's read) and
routed rework on that theory. Two different close-sequencing fixes were tried first on that
theory -- `:gen_tcp.shutdown(socket, :write)` half-close, then a full drain-until-peer-closes loop
before closing -- and **neither changed the failure at all**, which was the actual signal that the
diagnosis was wrong, not that the fix needed to be more aggressive. Byte-level tracing (a minimal
standalone `:gen_tcp` listener dumping every `recv` chunk with its size) showed the real shape:
one chunk containing the complete request, then a second `recv` call that legitimately had nothing
left to read and timed out.

**Correct alternative.** When a hand-rolled line/header-oriented TCP reader accumulates bytes across
multiple `:gen_tcp.recv` calls and then splits off "the header portion," the split's leftover must
be threaded through to whatever reads the body next -- never discarded on the assumption that a
`recv(socket, 0, _)` chunk boundary lines up with a semantic boundary (line, header block, etc.) in
the protocol being parsed. TCP has no message boundaries; a chunk is opportunistic OS buffering, not
a framing unit. If two failed fix attempts targeting a plausible-sounding theory (here: "it's a
close race") produce *zero change* in the failure's behavior or timing, that itself is evidence to
stop iterating on that theory and get a byte-level trace of what is actually on the wire before
trying a third variant of the same fix.

## handoffs/registry.json silently reformatted wholesale by a Windows/PowerShell-tooled session, causing every subsequent rebase on it to conflict on the entire file

**What happened (REQ-184's Step Final rebase, 2026-08-30).** `handoffs/registry.json`'s own header
comment says "Append-only ... never shrink, never regenerate wholesale." Despite that, at some point
between the REQ-198 registry update and this rebase, the file was re-serialized wholesale in a
distinctive PowerShell `ConvertTo-Json`-style format -- UTF-8 BOM, 4-space indent, a double space
after every `:`, `'`/`<`/`>` escapes for characters a Bash/Elixir-side JSON writer
would emit literally or with standard `\uXXXX` single-codepoint escapes. This happened independently
on *both* sides of the rebase (this branch's own tip, and origin/main's REQ-193 commit) from the
same clean, 2-space, no-BOM merge-base -- meaning at least one, likely both, of the ORCH sessions
doing Step 00/Step Final registry bookkeeping ran on a Windows host and used a PowerShell-based
JSON write path (`ConvertTo-Json | Out-File`) rather than an in-place text append or a JSON library
call that preserves the existing serialization style. The practical result: `git rebase` saw the
*entire* file as one giant conflicting hunk on every single commit in the branch that touched
`registry.json` (5 separate conflicts across a 12-commit rebase), even though the actual *content*
divergence on each side was exactly one new run entry with no data loss (independently verified: a
diff of all pre-existing `run_id` entries between the two reformatted versions showed zero content
mismatches -- only the new entries and the byte-level serialization differed).

**Correct alternative.** Detect this class early: if a rebase conflict on `registry.json` (or
`requirement_status.*.yaml`) produces a conflict spanning the *entire file* rather than a small hunk
near the append point, do not resolve it by picking one side's raw text -- parse both sides as JSON
(`python3 -c "json.loads(open(...).read().decode('utf-8-sig'))"`, handling the BOM), diff the
`run_id`/entry sets to confirm no content was actually lost on either side (it usually isn't; the
divergence is almost always exactly the two sides' own new entries), then re-serialize once with a
single clean, canonical format (2-space indent, no BOM, `ensure_ascii=False` to keep the `§`
characters literal rather than escaped) containing the union of both sides' entries. Do this once at
the rebase's first conflicting commit; every subsequent commit's registry.json conflict can then be
resolved by simply keeping the already-fixed file (`git checkout --ours handoffs/registry.json` mid
non-interactive rebase, since HEAD at that point is the already-composed-and-fixed prior commit) --
each later commit's own registry.json diff is just re-deriving the same single-entry update already
present. The deeper fix this doesn't address: whichever agent role or host environment last ran a
PowerShell-style `ConvertTo-Json` write against this file should be made to append via a
format-preserving method instead (a plain text-mode append of one new array element before the
closing bracket, or a JSON write that copies the source's existing `indent`/`separators`/`ensure_ascii`
settings) -- this is a recurring risk on any file this project's agents update from a mixed
Bash/PowerShell fleet, not unique to `registry.json`.

## Claiming a function "already carries" a value without reading its real parameter list -- three instances in one requirement's design

**REQ-195 (audit-entry storage), three separate occurrences before REVIEWER's gate, each caught
one function-call later than the last.** The design's original text asserted, as supporting
reasoning for using real actor ids in several audit rows, that a set of context functions
"already receives `actor_id` as an explicit Elixir-level argument." Each assertion turned out to
be checking the wrong thing -- a plausible inference from the *shape* of similar functions
elsewhere in the same module, not a read of the specific function's own `@type`/signature:

1. **Rework 1** -- `Letflow.Definitions.activate/2`/`deprecate/2`/`archive/2` were claimed to carry
   `actor_id` via `activate_opts()`. CODE-DESIGN-VALIDATOR read `activate_opts() :: [prefix:
   String.t(), service_scope_validator: ...]` directly and found no `actor_id` field anywhere.
2. **Rework 2** -- the same design, having just fixed instance 1, made an *adjacent* unverified
   claim to patch over the gap: that `activate/2` is "also called from system/scheduler-initiated
   paths with no human actor," citing two test-fixture-helper call sites as evidence. Verified
   directly this session: `grep -rn "Definitions.activate(" lib/` (excluding the design doc) finds
   exactly one production caller -- the router -- and the cited tests are fixture setup, not a
   real production system-driven path. The correction to instance 1 had introduced a second,
   equally unverified claim.
3. **Implementation** -- SECURITY-REVIEWER, re-checking the *shipped code* rather than the by-then-twice-corrected
   design doc, found the design's own §3.2 table still asserted `Letflow.Tasks.assign_task/3`
   "already has `actor_id` as an explicit, required field of `assign_attrs`." Reading
   `lib/letflow/tasks.ex` directly showed `@type assign_attrs :: %{required(:user_id) =>
   String.t()}` -- no `actor_id` field at all; only the *sibling* function `claim_task/3`'s
   `claim_attrs` carries it. ELIXIR-DEV caught this one itself before it shipped uncorrected and
   disclosed it in the handoff rather than papering over it, which is why it surfaced as a
   disclosed disposition rather than a fourth CODE-DESIGN-VALIDATOR rework cycle.

**Why this kept recurring despite being caught each time:** each claim was locally plausible --
`activate_opts()`, `assign_attrs`, and `claim_attrs` are all option/attrs types on sibling
functions inside the same module, and several *do* carry `actor_id` (`cancel_instance/3`'s
`attrs[:actor_id]`, `complete_task/3`'s `attrs[:actor_id]`, `claim_attrs.actor_id`). A design
author who has just confirmed the pattern holds for three or four functions in a family has a real
incentive to assume it generalizes to the rest of the family without re-checking each one
individually -- the claim reads as "obviously true by analogy" right up until the one function
that breaks the pattern is actually opened.

**Correct alternative:** when a design (or an implementation building on a design) asserts that a
specific named function "already carries," "already receives," or "already has" a value its
downstream logic depends on, that claim must be checked against *that exact function's own
`@type`/signature and body* -- not inferred from a sibling function in the same module, not
inferred from the module's general shape, and not treated as re-confirmed by fixing a
*different*, adjacent unverified claim. `grep -rn "<the exact function call>(" lib/` for real
callers, and reading the specific `@type` line, both cost one tool call and would have caught all
three instances on the first pass. When a design depends on several sibling functions having the
same shape, verify each one individually and say so explicitly (as REQ-195's final design does in
§3.1a/§3.1b) rather than asserting the family-wide generalization once and trusting it to hold for
every member.

## Ecto's default index/constraint naming can silently collide or exceed Postgres's 63-byte NAMEDATALEN limit -- invisible to a plain `mix ecto.migrate`

**REQ-202 (content-addressed artifact store), caught by TEST-DESIGNER's own test run against
real Postgres, not by review.** The migration declared both a `unique_index/3` and a plain
`index/3` on `artifact_versions(:artifact_kind, :artifact_name, :version_number)`, the second
with `desc: :version_number`. Ecto derives an index's default name from its column list alone --
the `desc:` annotation changes the generated SQL but not the derived name -- so both calls
produced the *identical* default name. That name was also 66 bytes, seven over Postgres's
63-byte `NAMEDATALEN` limit, so even a single occurrence would have been silently truncated to a
different, shorter identifier than what the code (here, `ArtifactVersion`'s
`@unique_version_number_constraint_name`, used by `unique_constraint/3`'s error-matching) assumed.
Two independent failure modes from one root cause: a **name collision** between two index
declarations, and a **truncation mismatch** between the constraint name Postgres actually stores
and the atom the schema module matches errors against.

**Why this is invisible to `mix ecto.migrate` alone:** that command runs the migration once,
against the `public`/non-tenant schema, in whatever database state the running session already
has. It never replays the migration into a *fresh* per-tenant schema the way
`Letflow.TenantProvisioning`'s real provisioning path does, so a collision between two index
names in the SAME migration only surfaces the moment Postgres is asked to create both inside one
schema from a clean slate -- exactly what TEST-DESIGNER's test run did (and what an interactive
`mix ecto.migrate` against a long-lived dev database, which already has the first index and skips
re-creating it, would not reproduce). Likewise, a truncated name compiles and migrates fine; it
only breaks the moment application code tries to pattern-match a Postgres error against the name
the code *assumes* was stored, which is a runtime-error-path test, not a migration-apply check.

**Correct alternative:** any migration whose index or constraint's default name is built from
more than two or three column names, or that mixes `desc:`/`asc:` direction annotations across
sibling index declarations on the same column set, should be given an explicit, short `:name`
option rather than trusting Ecto's default -- and that default should be computed and checked
against the 63-byte limit by hand (`column_list |> Enum.join("_") |> then(&"#{table}_#{&1}_index")
|> byte_size`) before relying on it, not assumed safe because the migration compiles. A design or
review pass that only reads the migration's DDL cannot catch this class either -- it takes an
actual replay against a real, freshly-provisioned per-tenant schema (TEST-DESIGNER's or
TEST-RUNNER's own suite run, not `mix ecto.migrate`) to surface it.

## A new tenant-scoped migration's tables must be added to `test/support/tenant_fixture.ex`'s `@expected_tenant_tables` oracle in the SAME change -- three occurrences, and it was never actually documented here until now

**REQ-181 (webhook_subscriptions), REQ-195 (audit_entries), and now REQ-202
(artifact_versions/repository_artifacts) each independently forgot this step**, and each was
caught by the SAME guard test (`Letflow.Support.TenantFixtureTest`'s "C6 -- oracle-rot guard",
which asserts the set of tables a real tenant-schema provisioning run actually creates equals
`@expected_tenant_tables/0` in both directions) rather than by review. REQ-202's own TEST-RUNNER
handoff (step-04-test-runner.json) asserted in passing that this was "the exact same recurring
bug class documented on REQ-181 ... and REQ-195" -- but at the time that sentence was written, no
anti-patterns.md entry for it actually existed: neither prior occurrence had been filed here, so
there was nothing in this file an ELIXIR-DEV session could have grepped for to pre-empt REQ-202's
own instance before TEST-RUNNER caught it a third time. This entry is that filing, after the fact,
for all three.

**The mechanism, each time:** a migration adds one or more new `prefix: schema`-scoped tables
(`priv/repo/migrations/`), and `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s manifest
is updated to run it during provisioning -- but `test/support/tenant_fixture.ex`'s
`@expected_tenant_tables` list, a separate, hand-maintained oracle of every table a freshly
provisioned tenant schema should contain, is a different file with no compiler or migration-runner
link forcing it to move in lockstep. C6's guard test is the only thing that notices the drift, and
it only fires when the full suite (or that specific test file) is actually run against a real,
freshly provisioned schema -- exactly the category of check `mix ecto.migrate` alone (see this
file's adjacent NAMEDATALEN entry) cannot perform either.

**Correct alternative:** any requirement whose acceptance criteria include a new tenant-scoped
migration should treat updating `@expected_tenant_tables` (and the paired count assertion in
`test/letflow/support/tenant_fixture_test.exs`) as part of that migration's own diff, not a
follow-up -- ELIXIR-DEV should grep for `@expected_tenant_tables` and add the new table name(s)
in the same commit that adds the migration, before TEST-DESIGNER or TEST-RUNNER ever runs C6
against it. Now that this is a filed, three-occurrence pattern, a fourth instance should be treated
as a signal that the check itself belongs closer to the migration (a compile-time or
migration-review assertion cross-referencing the manifest against the oracle list) rather than
left to whichever downstream test happens to run C6 first.

## Claiming a DEPENDENCY's runtime behavior without reading its actual source -- two opposite false claims in one requirement's design stage

**REQ-203 (per-tenant artifact activation), design stage, two rounds in a row -- distinct from the
REQ-195 entry above.** That earlier entry ("Claiming a function 'already carries' a value without
reading its real parameter list") is about misjudging THIS CODEBASE's own function signatures by
analogy to sibling functions. This is a different defect class: misjudging a THIRD-PARTY
LIBRARY's (Ecto's) actual runtime behavior, stated as settled fact without reading that library's
source, in two opposite directions on the same requirement:

1. **Original design (§2.4/OQ-D)** claimed `validate_required(:rationale)` "may not reject" a
   whitespace-only string, and defended against that gap by ALSO adding `validate_length(min: 1)`
   -- which is equally defeated by a whitespace-only string, since `validate_length/3` counts
   `String.length/1` on the raw value and `"   "` has length 3, not 0. Neither validator, as
   described, actually closed the gap the design believed it was closing.
2. **Rework 1's fix** overcorrected to the opposite wrong claim: that `validate_required(:rationale)`
   "does NOT reject" a whitespace-only string because `cast/4` "never nils it out." CODE-DESIGN-
   VALIDATOR's recheck1 read `deps/ecto/lib/ecto/changeset.ex`'s actual `cast_field/9` pipeline
   directly (the `filter_values` lambda at line 774, `Ecto.Type.trim/2` at `deps/ecto/lib/ecto/
   type.ex:1007`) AND ran a throwaway empirical script against this project's real pinned Ecto
   3.14.1 dependency: `cast(%{"rationale" => "   "}) |> validate_required(:rationale)` produces
   `valid?: false`, `errors: [rationale: {"can't be blank", ...}]` -- `Ecto.Type.trim/2` strips
   LEADING whitespace before `validate_required/2` ever runs, so an all-whitespace string collapses
   to `""` and IS rejected. Only rework 2's design got this right, and only after both a source
   read and a real, dependency-linked reproduction were done together (see
   `handoffs/WF02-REQ203-20260831/step-01b-code-design-validator-recheck1.json`,
   `-recheck2.json`).

**Why this is worth its own entry, not folded into REQ-195's:** the REQ-195 pattern is caught by
reading `@type`/signature lines already inside `lib/`; this pattern requires reading a *vendored
dependency's* source (`deps/<pkg>/lib/...`) and, ideally, running a small real reproduction against
the project's actual pinned version -- a plausible-sounding claim about a widely-used library
function (`validate_required`, `validate_length`) is exactly the kind of thing an author is tempted
to state from general familiarity rather than checking against the specific version pinned here.

**Correct alternative:** any design or implementation claim about what a third-party
library/framework function does or does not reject/accept/mutate must be checked against that
library's actual vendored source under `deps/` for the version this project has pinned (`mix.lock`),
not stated from general familiarity with the library -- and where the behavior is genuinely
load-bearing for an acceptance criterion (as `validate_required`/`validate_length`'s whitespace
handling was here, for AC6), back the source read with a real, throwaway reproduction against the
actual dependency rather than trusting the source read alone to have been interpreted correctly.

## A test-only production-code seam added after REVIEWER's sign-off needs a fresh REVIEWER pass, not just TEST-DESIGN-VALIDATOR's

**REQ-203, Step 3 (TEST-DESIGNER) added a `test_pause_after`/`test_pause_fun` synchronization hook
to `activate_group/4` (bumping its arity to 5) AFTER REVIEWER had already PASSED the implementation
at Step 2d.** TEST-DESIGN-VALIDATOR (`handoffs/WF02-REQ203-20260831/step-03b-test-design-validator.json`)
made the correct call here, but the workflow doc (`docs/agents/workflows/WF-02_requirement_
implementation.md`) does not currently say this explicitly anywhere, so a weaker or less careful
agent could plausibly reason "TEST-DESIGN-VALIDATOR already checked the diff is behavior-preserving,
that's enough" and skip re-routing to REVIEWER. TEST-DESIGN-VALIDATOR's own reasoning for why that
would have been wrong: this is new production-file surface (a changed public arity, a new `@type`)
landing in `lib/letflow/repository/activation.ex` that REVIEWER has literally never seen, regardless
of how carefully TEST-DESIGN-VALIDATOR itself verified the diff is additive and a structural no-op
outside `MIX_ENV=test` -- CLAUDE.md's central redundancy principle ("every producing step has a
validating step... adopted specifically so the pipeline stays reliable even when the executing model
is weak") does not carve out an exception for changes that *look* safe. The seam needed TWO REVIEWER
rework rounds before it re-passed cleanly (`step-02d-reviewer-recheck1.json`,
`-recheck2.json`) -- it was not a rubber-stamp re-approval.

**Correct alternative:** whenever a later pipeline step (TEST-DESIGNER, ELIXIR-DEV rework, or anyone
else) modifies a file under `lib/` or `priv/repo/migrations/` that REVIEWER already PASSED earlier in
the same run -- even a change TEST-DESIGN-VALIDATOR itself judges to be additive, behavior-preserving,
and gated to `MIX_ENV=test` only via `Application.compile_env/3` -- route back to REVIEWER for a fresh
pass on the actual new diff before TEST-RUNNER, rather than treating TEST-DESIGN-VALIDATOR's own
regression-suite re-run as a substitute for REVIEWER's idiom/scope gate. This should be made explicit
in `docs/agents/workflows/WF-02_requirement_implementation.md`'s Step 2d/Step 3 description rather
than left to each TEST-DESIGN-VALIDATOR run to reason out independently, since it worked out correctly
here but is exactly the kind of judgment call a future run could get wrong under time pressure.

## An established template-substitution mechanism applied to two of three sibling code paths, not all three

**What happened.** REQ-205's `Letflow.Simulation.Runner.verify_outcome/2` has three
`expected_outcomes.verification.method` clauses -- `task_assigned`, `instance_state`, and
`audit_event` -- each meant to resolve `{{produces.X}}` template references (a prior step's
captured runtime output, e.g. an instance id) before querying real state. The first two
clauses did this correctly via a shared `resolve_ref/3` helper. The third, `:audit_event`,
was implemented with the exact opposite: it took `produces` as a parameter named `_produces`
(the underscore-prefix Elixir convention for "intentionally unused") and never touched it,
so a scenario's `audit_event` outcome referencing `resource_id: "{{produces.instance.
instance_id}}"` silently matched nothing instead of resolving to the real id or failing
closed. Caught by TEST-DESIGNER at Step 3 (not CODE-DESIGN-VALIDATOR, not REVIEWER, not
SECURITY-REVIEWER -- all of whom saw the same function earlier and passed it), fixed by
ELIXIR-DEV rework 1 with a new `resolve_optional_ref/3` mirroring the existing
`resolve_ref/3`, plus two regression tests proving real substitution and real
query-scoping.

**Why this is a distinct class from a missing mechanism.** The gap here was never "does
this codebase have a way to resolve `{{produces.X}}`" -- it manifestly did, used correctly
in the other two clauses right above and below the broken one in the same function. The
defect is a *partial application* of an already-established mechanism: one sibling branch
of a multi-clause dispatch quietly opted out (via a parameter name suggesting the omission
was deliberate design, not oversight) while its neighbors used the real thing. This is
harder to catch by reading any one clause in isolation -- `_produces` reads as intentional,
unused-arg hygiene, not as a bug -- and only becomes visible by diffing the three clauses'
handling of the same conceptual input against each other.

**Correct alternative.** When a function has multiple clauses/branches implementing the
same conceptual step for different cases (here: three verification methods all needing to
resolve template references before use), diff their handling of that shared concern against
each other explicitly, rather than reviewing each clause only against its own acceptance
criterion in isolation. A parameter prefixed `_` in one branch when its siblings use the
same-named parameter for real is a specific, greppable smell worth checking on sight in this
class of multi-clause dispatch code.

## Handoff schema drift produced by ORCH's own dispatched subagents within a single run, not a sibling-session collision

**What happened.** `docs/anti-patterns.md`'s existing handoff-schema entries (see "Subagents
write a handoff's top-level `status` field with an ad hoc value instead of the schema enum",
above) and its handoffs/registry.json entries all describe drift introduced by *independent,
concurrently-running sessions* stepping on shared state. WF02-REQ205-20260831 surfaced a
different mechanism: 6 of that single run's own handoff files -- all written by subagents
ORCH itself dispatched in sequence within this one run (`step-02a-elixir-dev(.json/
-rework1)`, `step-02c-security-reviewer`, `step-02d-reviewer(.json/-recheck1)`,
`step-03-test-designer`, `step-03b-test-design-validator`) -- store verdict/result-shaped
data (`summary`, `verdict`, `per_ac_findings`, `mutation_test_results`,
`findings_for_orch`, etc.) inside the handoff's `context` block instead of the schema's
`task`/`result` blocks. `mix letflow.lint_handoffs` flagged this as 8 new `[H3]`
non-schema-top-level-key violations (found by TEST-RUNNER at Step 4, independently
reconfirmed by RELEASE-VALIDATOR at Step 5); neither step corrected the 6 pre-existing
files, since fixing another step's already-completed handoff was out of scope for both.

**Why this is worth a separate entry, not folded into the sibling-session cases.** The
existing entries' mitigations (grep the top-level `status` field before dispatching the next
step; a git pre-push hook running the lint) are aimed at catching drift *between* sessions
racing on shared files. This drift had no race at all -- every one of the 6 files was
written once, by one subagent, in one linear run, with no concurrent writer to blame. That
means the standard mitigation (inline vigilance from ORCH between steps) was fully available
and simply didn't fire: ORCH dispatched each of these 6 steps and received each of their
handoffs before dispatching the next, so a `mix letflow.lint_handoffs` check at each
dispatch boundary -- not just before a PR/CI push -- would have caught this at step-02a
already, five steps before TEST-RUNNER's Step 4 did.

**Correct alternative.** Run (or at minimum, structurally check for `context`-block keys
that shadow `task`/`result` field names like `summary`/`verdict`/`findings_for_orch`)
`mix letflow.lint_handoffs` immediately after receiving *any* subagent's handoff, not only
before a push/PR -- the existing entries already recommend this for the top-level `status`
enum specifically; this occurrence shows the same discipline is needed for the
context-vs-task/result shape distinction too, and that "no concurrent writer" is not a
reason to expect schema drift to be absent.

## Orchestrator log claims progress with no corresponding handoff artifact or registry entry

**What happened.** WF02-REQ207-20260901's originating session appended four real,
timestamped entries to `handoffs/orchestrator.log` (STEP_COMPLETE for Step 00, DISPATCH
and STEP_COMPLETE for Step 01 CODE-DESIGNER, and a DEFER_RUN entry stating Step 1b would
"resume now") and committed real artifacts for some of that work (the feature branch, the
actual design doc at `lib/letflow/design/req207-vortex-scenario-execution.md`, commit
`7d0494b8`) -- but never created `handoffs/WF02-REQ207-20260901/` at all, and never added
a `handoffs/registry.json` entry for the run_id. A later ORCH session picking this run back
up at REQ-206's Step Final found the log narrating a fully-formed pipeline (queue lock,
branch, design PASS, validator "resuming") with zero corresponding JSON handoff files and
no registry row -- meaning `mix letflow.lint_handoffs`'s own H5 registry-coverage check
would never have caught this either, since H5 only diffs run_ids that exist in *at least
one* of the two places against each other, and this run_id existed in neither.

**Why this is a distinct case from the other handoff-drift entries above.** Those entries
are about a handoff *existing* with the wrong shape (wrong top-level keys, wrong `status`
enum, wrong file schema). This is about a handoff step being *narrated in prose* with real
timestamps and real git commits as corroborating evidence, while the actual per-step JSON
artifact the schema requires was never written at all. The log entry alone reads as
credible completed work -- it cites a real commit hash, a real dependency check, a real
file path -- which makes it easy to trust at face value rather than checking for the JSON
file the log entry claims to summarize.

**Correct alternative.** Before trusting any orchestrator.log entry (yours or a sibling
session's) as evidence a step completed, confirm the handoff JSON file it should have
produced actually exists on disk, and confirm `handoffs/registry.json` carries a row for
the run_id (not just relying on H5's on-disk-vs-registry diff, since a run_id absent from
*both* never surfaces there). A log entry citing a real commit is real evidence that *code*
was written, but is not itself evidence that the *handoff artifact* for that step exists --
those are two different claims and a session can satisfy one without the other. When the
gap is found, reconstruct the missing handoff(s) from git history and the log's own
entries (never invent facts not already evidenced) rather than either re-running the step
from scratch (duplicating already-real work) or silently proceeding without the artifact.

## A documented design-doc OQ flagging a real Engine gap can survive its own "future
## requirement" untouched, because unit tests exercise the wrong layer

**What happened.** REQ-208 (S7, Meridian committee-quorum/parallel-fork-join scenarios)
needed a real `PARALLEL_GATEWAY` split whose branches (`credit-memo-review`,
`risk-assessment`, both real `HUMAN_TASK`s) converge at a join, completed via two
*separate* `POST /api/v1/tasks/:id/complete` HTTP calls (one actor per branch, at
different times -- the ordinary real-world shape). The first branch's completion failed
with a real HTTP 500 every time, `{:error, {:activation_failed, {:unknown_branch_id,
_}}}` internally. Root cause: `lib/letflow/engine.ex`'s `build_instance_state/3`
hardcodes `join_counters: %{}` on every call -- confirmed by that function's own code
comment, which cites `lib/letflow/design/req048-task-completion.md`'s own §13 "OQ-3
(MAJOR)": *"no table persists join-counter state today ... deferred to whichever
requirement first persists join-counter state (REQ-053/054 territory)."* REQ-054
(SnapshotWriter) later shipped `status: done` and DOES serialize `join_counters`
correctly into `instance_state_snapshots` (`lib/letflow/engine/snapshot_writer.ex`) --
but `Engine.complete_task/3`'s own hot path (`build_snapshot_and_state/4` ->
`build_instance_state/3`) never reads that table at all; it always rebuilds state fresh
from `tokens`/`tasks` directly, with `join_counters` left at the same hardcoded `%{}`.
The OQ was never actually closed, just designed-around one layer over.

**Why S3's own unit tests didn't catch this.** `test/letflow/engine/parallel_gateway_test.exs`
(REQ-051, "done", one of the most directly relevant test files in the whole codebase to
this defect) calls `Transition.transition/3` directly, in-memory, across a sequence of
calls *within one Elixir test process* -- the `join_counters` map genuinely does persist
there, because it's just a local variable threaded through direct function calls, not
reconstructed per call the way a real `POST` request's own `Engine.complete_task/3`
invocation reconstructs `InstanceState` fresh from the database every time. A green,
passing `parallel_gateway_test.exs` is therefore evidence that `Transition`'s *own join
logic* is correct, and is NOT evidence that a join can fire across two separate real API
calls -- those are different claims, and nothing in the existing test suite exercises the
second one. This is the same shape of gap `docs/anti-patterns.md`'s "inheriting a claim
from a record instead of re-deriving it from the source" entry warns about, one level
removed: here the record (a design doc's own MAJOR OQ, explicitly deferred to a named
future requirement) was correct and specific, and the future requirement genuinely
landed -- it just solved a different half of the problem than the OQ described, and
nothing forced a re-check that the OQ's own literal failure mode (`{:unknown_branch_id,
_}`) was gone.

**Correct alternative.** When a design doc's own OQ says "deferred to REQ-NNN," landing
REQ-NNN is not itself proof the OQ is closed -- re-read the OQ's own literal failure
mode/error tuple and confirm a *new* test reproduces the original failing call path (not
just a new unit test of REQ-NNN's own added code in isolation) before treating the gap as
resolved. More generally: a unit test that calls an internal function (`Transition.transition/3`)
directly, across multiple calls in one process, is not equivalent evidence to a test that
drives the same logic through the real, per-request state-reconstruction path
(`Engine.complete_task/3`, which rebuilds `InstanceState` from the database on every
call) — the first proves the algorithm; only the second proves the request path. Treat
"S3 unit-tested it" as a claim about the algorithm, not about the wire-level behavior,
when the two paths reconstruct state differently.

## A volume-closure footer missing the exact "VOLUME N — CLOSED" marker format silently fails the A7 invariant

**What happened.** WF02-REQ208-20260901's DOC-UPDATER closed
`docs/status/requirement_status.v7.yaml` (crossed the 1200-line roll ceiling) and wrote a
closure footer that read every prior closed volume's *content* convention correctly (frozen
byte range, "why closed" prose, pointer to the new current volume) but wrote the marker line
itself as `# VOLUME 7 CLOSED 2026-09-01.` — omitting the em-dash every other closed volume's
marker uses (`# VOLUME N — CLOSED <date>. DO NOT APPEND TO THIS FILE.`). `test/support/
status_history.ex`'s `closure_footer/1` locates a volume's footer via
`Regex.match?(~r/VOLUME \d+ .* CLOSED/u, line)` — that pattern requires *something* between
the volume number and `CLOSED`; the bare `VOLUME 7 CLOSED` has nothing there, so the regex
never matched and `closure_footer/1` returned `nil` for a volume that visibly has a footer to
a human reader. `test/docs/requirement_status_invariants_test.exs`'s A7 assertion ("every
closed volume's footer names the next volume") consequently failed with `:no_closure_footer`
— caught only because a later ORCH session ran the full invariants suite before Step Final,
not because DOC-UPDATER's own work ran it (the reworked session that closed the volume
reported "mix/elixir not present in this sandbox" and never ran the test at all — see the
separate entry below on verifying that exact claim before trusting it).

**Why this is easy to miss.** The footer content itself was substantively correct — the
volume really was over its ceiling, the "why closed" reasoning was accurate, the new current
volume was correctly named in prose. Only the single marker LINE'S punctuation was wrong, and
nothing about reading the file makes that omission look wrong to a human — the sentence
reads fine either way. The defect is only visible to the regex the test actually runs.

**Correct alternative.** When closing a volume, copy the marker line's exact punctuation from
the most recently closed volume's own footer (`grep -n "CLOSED" docs/status/
requirement_status.v*.yaml`) rather than composing it from the surrounding prose's memory of
the convention. After writing a closure footer, always run
`mix test test/docs/requirement_status_invariants_test.exs` for real before considering the
volume-roll step done — this is exactly the kind of one-character-of-punctuation defect that
"the prose reads correctly" review cannot catch but the invariant test catches immediately.

## Trusting a subagent's "toolchain not available" claim without independently checking it

**What happened.** WF02-REQ208-20260901's DOC-UPDATER reported "mix/elixir are not present
in this sandbox at all (confirmed via which/filesystem search)" and used that to justify not
running the live-drift test it should have run, reasoning from the detector's documented
rule in prose instead. A later ORCH session sourced `~/.asdf/asdf.sh` in the same repository
checkout and ran `mix test` successfully within seconds — the toolchain was fully present the
whole time; the subagent's shell simply never sourced asdf before checking. The prose-based
reasoning happened to reach the same correct conclusion this time (S7 was already active, no
change needed), but the underlying practice — accepting "the tool isn't available" as a
justification for skipping a real check, from one shell session's unverified negative result
— is exactly backwards from this project's "run it, don't reason about whether it would pass"
discipline, and this session's own established recipe for the toolchain (`source
~/.asdf/asdf.sh 2>/dev/null` before any `mix`/`elixir` invocation) was not applied.

**Correct alternative.** Before accepting any "the toolchain isn't available here" claim —
your own or a sibling's — try `source ~/.asdf/asdf.sh 2>/dev/null; which mix` (or the
project's currently-documented equivalent) yourself before concluding a check cannot be run.
A negative result from one un-sourced shell is not evidence the toolchain is absent from the
sandbox; multiple agents in this exact session, in the exact same environment, ran `mix`
successfully throughout.

## A gate-approved design fixing a shared write function missed a sibling write path constructing the same state independently

**What happened.** ISS-0397's design (`lib/letflow/design/iss0397-join-counters-fix.md`,
gate-approved by CODE-DESIGN-VALIDATOR) correctly identified `reconcile_projection/5` as the
one function shared by `complete_task/3`'s and `advance_after_timer_fired/3`'s own
`Ecto.Multi` write sites for `instance_projections`, and fixed it to persist
`join_counters`. It did not notice that `Letflow.Engine.create/2` has its OWN, separate M1
insert (`insert_instance_projection/8`) that also builds an `instance_projections` row from a
freshly-dispatched `InstanceState.t()` — and that a `PARALLEL_GATEWAY` split reachable within
`create/2`'s own initial hop-chain (the exact shape the design's own §5.1/§5.3 test fixtures
use: split immediately after `START`) leaves that row's `join_counters` silently defaulted to
`%{}` at insert time, with no later call ever correcting it. Caught only because
ELIXIR-DEV ran the newly-written regression test for real before considering the fix done —
the test failed with `map_size(join_counters) == 0`, not the expected `1`, immediately after
`Engine.create/2`, before either `complete_task/3` call ran.

**Why this is easy to miss.** The design's own source list (§0) enumerated every function
that *reads* `InstanceState.join_counters` and every function that *writes* it back to
`instance_projections` via `reconcile_projection/5` — but `create/2`'s insert path builds an
`instance_projections` row through a structurally different function
(`insert_instance_projection/8`, called from `persist/12`'s own Multi, never
`reconcile_projection/5`) that happens to construct the *same kind* of row from the *same
kind* of `InstanceState.t()`. Grepping/reading for "every call site that touches
`join_counters`" naturally follows already-known references to the field; it does not
surface a write site that never mentioned `join_counters` at all because that's precisely the
bug — the field was never being written there.

**Correct alternative.** When a design fixes a hardcoded/defaulted value read from or written
to a shared struct, grep for every OTHER place that constructs the same struct type from
scratch (here: every call site that builds an `instance_projections` row, not just the ones
already named for handling the field in question) — not just every existing reference to the
field being fixed. Then verify with a real, running regression test that exercises the
specific scenario the fix's own test fixtures use (here: a split immediately after `START`,
inside `create/2`'s own hop-chain) before considering a design's write-site enumeration
complete, even one that has already passed CODE-DESIGN-VALIDATOR.

## ISS-0397's own join_counters fix still missed a THIRD sibling read/write path, in a different module — plus a Multi-step-ordering bug only that path exposed

**What happened.** The entry directly above this one documents ISS-0397's fix missing
`Letflow.Engine.create/2`'s own `insert_instance_projection/8` (a sibling *write* path to the
`reconcile_projection/5` the design fixed). Implementing ISS-0396
(`lib/letflow/design/iss0396-task-records-multi-sibling-fix.md`) surfaced a FOURTH function
that builds/mutates the same `join_counters` state independently, in a different module
entirely: `Letflow.Engine.SubProcess.load_parent_context/2` (sub_process.ex) — the seed-state
builder used specifically for a sub-process completion cascade — still hardcoded
`join_counters: %{}` rather than `SnapshotWriter.deserialize_join_counters(projection.join_counters)`,
and its write-side sibling, `reconcile_parent_projection/5` in the same module, never
persisted `join_counters` back to the row at all (not even a defaulted/wrong value — the
field was simply absent from its `attrs` map). Neither defect was reachable by any test in
the suite before ISS-0396's own regression test, because no prior test drove 2+ sibling
`SUB_PROCESS` children through a real `PARALLEL_GATEWAY` join via this specific module's own
seed/reconcile pair — every earlier sub-process test either had no join at all, or reached one
via `Letflow.Engine`'s own (already-fixed) `build_instance_state/3`/`reconcile_projection/5`
pair, never `SubProcess`'s own copy. A THIRD, architecturally distinct bug came with them: the
root instance's own `INSTANCE_STARTED` event append (`persist/8`'s `:event` Multi step) was
positioned *after* the `build_sub_process_children_multi/6` merge, on the implicit assumption
that nothing before it could change the row's status away from the `:active` the
`:instance_projection` step (M1) had just inserted — false once a synchronously-completing
`SUB_PROCESS` cascade writes that same row's status to `:completed` (via
`reconcile_parent_projection/5`, a direct write, not gated by `EventStore.append/2`'s own
`active_instance_guard`) *before* M3 ever runs. All three were caught only because ELIXIR-DEV
ran the new regression test for real, iterated on the actual failures (`cannot merge Multi`,
then a wrong final `:active` status, then `{:event_append_failed, {:instance_terminated,
:completed}}`), and root-caused each one rather than declaring the design's own two-file
change ✅ once it compiled.

**Why this is easy to miss.** Each of these three functions/steps is written, commented, and
positioned as if it were the ONLY place its concern lives — `load_parent_context/2`'s own
moduledoc-adjacent comment doesn't mention `join_counters` at all (it predates ISS-0397),
`reconcile_parent_projection/5` mirrors `reconcile_projection/5`'s attrs shape closely enough
to look complete at a glance, and `persist/8`'s own M1 comment ("M4 below flips the row to its
true final status immediately after the event append succeeds") is correct for every scenario
tested until ISS-0396's — it just never accounted for a WRITE to the same row happening
*between* M1 and M3 via an entirely different code path (`SubProcess`'s own cascade, not
`persist/8`'s own M4/`:finalize`). None of these are visible from reading any ONE of the three
functions in isolation; each only shows up as a live, reproducing test failure.

**Correct alternative.** Same core lesson as the entry above, generalized: a struct-shaped
piece of state (`join_counters`, an `instance_projections` row's `status`) that is
read/written from more than one module is not "handled" until every module's own copy of the
read/write logic is checked — not just the ones the current design's own file-touch list
names. When a design's own regression test exercises a genuinely novel code path (here: a
ROOT instance's own SUB_PROCESS children completing synchronously through a real join, inside
`Engine.create/2`'s own transaction, confirmed nothing in the existing suite exercised this
before), do not assume the surrounding, already-shipped machinery is safe by virtue of being
already-shipped — run the test, read the real error, and re-derive from the actual failing
code path rather than from what the design document assumed. Both fixes are captured under
`fix(ISS-0396)` for the sibling-key-collision issue that prompted their discovery; they are
each also independently a bugfix in their own right, unrelated to the collision itself.
## Retrying a `register_task` POST after misreading its success response

On 2026-09-03, registering the requirement now numbered REQ-222 (drafted as REQ-219,
renumbered on rebase -- see below) produced two queue tasks for one requirement: 449
(GH#862, the real one) and 450 (GH#863, a duplicate), seconds apart. The first POST
succeeded and returned the created task. It was piped into a parser that read `id`,
`impl_order`, `github_issue_number` and `status` from the **top level** of the response
body — but `letflow-queue` nests the task under a `data` key
(`{"error": null, "data": {"id": 449, ...}}`). Every field came back `None`, the call was
read as having failed, and it was re-issued. The second POST also succeeded, because
`register_task` has no idempotency key and nothing about a repeated title, description or
`stage` makes it refuse.

**`register_task` is not idempotent and cannot be safely retried on an ambiguous result.**
Unlike `set_lock` (idempotent for the same `agent_id`) or `release_lock` (converges on an
already-released task), every `register_task` call unconditionally allocates a new
autoincrement id, and — because the id doubles as `issue_ref` and as the `/tasks/<id>/...`
address — also files a new GitHub issue. A retry does not converge; it forks.

The parsing slip is the shallow cause. The real one is treating "my parser printed
nothing" as equivalent to "the server did nothing," for a call that had in fact fully
succeeded and had already produced a durable, externally-visible side effect (a GitHub
issue). A write whose result you cannot read is not a write that did not happen.

**Correct alternative:** on any `register_task` whose response you cannot confidently
parse, do **not** re-POST. Print the raw body first (`curl -s -w "\nHTTP:%{http_code}\n"`,
no parser in the pipeline) and read the actual status code and payload. The shape is
`{"error": ..., "data": {...}}` — read ids from `data`, not the top level. If the raw body
is genuinely unavailable, the recovery is a **read**, not a retry: once `GET /tasks`
exists (REQ-222, decision 0017 §B) it answers "did my task land" directly; until then, the
next `register_task` response's `id` reveals whether the sequence advanced by one or two.

If a duplicate has already been created: it cannot be deleted — the service exposes no
delete, by design. Retire it with `release_lock(status: "done")`, which also closes its
linked GitHub issue, and comment on that issue saying it was never real work and naming
the surviving task. Record the surviving id in `docs/requirements.yaml` with a note that
the neighbouring id is a retired duplicate, so a later reader finding two near-identical
issues does not go looking for a second requirement that never existed. This was done for
449/450 the same minute; total exposure was under two minutes, with neither task ever
dispatched to a workflow.

## Drafting new requirements with a blank `impl_order:`, then "fixing" it with a stale deferral marker

On 2026-09-05, REQ-ANALYST drafted 10 new requirements (REQ-232..242, ISS-0424 parts 2/3)
directly into `docs/requirements.yaml` without registering them via `letflow-queue`'s
`register_task` first, and left each with a bare `impl_order:` key and no value. `mix
letflow.check_requirements_registration` classifies a valueless key as `:unclassified`
(R2, hard fail) rather than `:deferred` — it matches neither the registered-field shape
nor the deferred-marker shape. Neither REQ-ANALYST nor REQ-VALIDATOR ran the local gate
before ORCH committed and pushed, so the PR's first CI run failed in ~45 seconds on this,
not on any test.

**The first fix was itself wrong.** ORCH's first response was to swap the blank field for
the documented deferred-marker comment (`# impl_order: UNREGISTERED -- <rationale>`,
matching REQ-223/REQ-224's existing usage) — which satisfies
`check_requirements_registration` but is a *different* check's job to gate:
`mix letflow.check_deferral_staleness` immediately failed all 10 with "STALE deferral --
stage-scoped; stage S6 is ACTIVE". A deferral is only legitimate when the rationale is a
live, expiring condition (`blocked-by: REQ-NNN`, checked against that requirement's actual
status) — REQ-223/REQ-224's precedent works because REQ-222 is genuinely still open, not
because "not yet registered" is itself an acceptable rationale. These 10 requirements had
no real blocker (REQ-238/239's real dependency on the others is already expressed via
`depends_on:`, not a deferral), so "unregistered" alone was never a legitimate reason to
defer — it just means: go register it.

**The actual fix:** call `register_task` for each requirement (in dependency order, so a
dependent's real integer `depends_on` list can reference its prerequisites' freshly-
allocated queue ids — recall `depends_on` takes queue-task integers, not `REQ-` strings),
then write the real `impl_order: <id>  # letflow-queue task id` into each entry.

**Lesson:** an `:unclassified` failure on a *freshly drafted, not-yet-registered*
requirement is not evidence that the deferred-marker form applies — it's evidence the
requirement should be registered now, unless there's a genuine, independently-checkable
blocking condition. Whoever drafts or validates a new `docs/requirements.yaml` entry
should run both `mix letflow.check_requirements_registration` and `mix
letflow.check_deferral_staleness` locally (both fast, no queue call needed for either)
before handing off or committing — each check gates a different failure mode, and passing
one says nothing about the other.
