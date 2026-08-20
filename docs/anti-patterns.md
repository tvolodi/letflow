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
