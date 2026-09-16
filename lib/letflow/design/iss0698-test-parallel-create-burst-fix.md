# ISS-0698 — `scripts/test_parallel.sh` parallel `ecto.create`/`ecto.migrate`
   burst fix design

**Status:** design, awaiting CODE-DESIGN-VALIDATOR.
**Run:** WF03-ISS0698-20260917, branch `feature/WF03-ISS0698-20260917`.
**Scope:** `scripts/test_parallel.sh` Step 2 launch phase (new Step 1.7 inserted
before it), plus a narrow, opt-in, backward-compatible `mix.exs` alias change
flagged below for REVIEWER attention. No implementation code below — shapes,
env-var contracts, formulas, and insertion points only.
**Explicitly out of scope:** `N`-derivation logic (`docs/migration/decisions/
0009-test-parallel-pool-sizing.md`'s AC4 lock, restated by ISSUE-FIXER's
diagnosis — not reopened here); the existing `TEST_POOL_SIZE` clamp formula
(Step 1.5, unchanged); `lib/mix/tasks/letflow.check.test.ex`'s log-parsing
contract (unchanged — still reads `partition-*.log` files the same way).

---

## 0. Sources read for this design

- `docs/issues/ISS-0698.yaml` (full).
- ISSUE-FIXER's diagnosis, as restated verbatim in this design's dispatching
  handoff (Step 1 of this run) — not re-derived here. Root cause: Step 2's
  launch loop backgrounds all `N` partitions' `mix test --partitions N`
  processes simultaneously with no stagger/cap; `mix.exs`'s `test:` alias
  (`["ecto.create --quiet", "ecto.migrate --quiet", "test"]`) means each of
  those processes independently runs `ecto.create` then `ecto.migrate` before
  ever reaching the test phase; `ecto.migrate` calls `Mix.Ecto.ensure_started/2`,
  which starts a full `Letflow.Repo` application instance at that partition's
  own `TEST_POOL_SIZE`-sized pool — a pool-open event distinct from (and prior
  to) the steady-state test-phase pool the existing clamp (Step 1.5) was sized
  for. All 16 partitions hit this pool-open at the same wall-clock instant,
  transiently exceeding the budget the clamp only bounds at steady state.
- `scripts/test_parallel.sh` (full, current state) — Step 0 (N-derivation),
  Step 1 (single pre-compile), Step 1.5 (`TEST_POOL_SIZE` clamp), Step 1.6
  (sequential per-partition `_build/test-partition-<i>` seeding — the
  precedent for "insert a new sequential/capped step between 1.5 and 2"),
  Step 2 (current unstaggered launch loop), Step 4/5 (log-parsing and exit
  contract — unaffected by this design).
- `mix.exs` lines 94-99 — the `test:` alias definition this design proposes
  making conditionally skippable (see §3).
- `lib/mix/tasks/letflow.check.test.ex` (moduledoc + task body) — confirms it
  shells to `scripts/test_parallel.sh` with no `TEST_PARALLEL_N` set, and reads
  only the `test_parallel: partition logs in <dir>` line plus each
  `partition-*.log`'s `Result:`/`Failed:` lines — nothing here depends on how
  Step 2 internally staggers its launches, so this design does not need to
  touch that file (see §5 for why option 2 from the dispatching handoff is
  declined).
- `docs/migration/decisions/0009-test-parallel-pool-sizing.md` (full,
  including all four addenda) — the locked clamp-not-hard-fail decision and
  its "two named non-pooled sources" precedent (ISS-0287, ISS-0515/0426),
  which this fix's problem is structurally analogous to: a source of
  connection demand the existing `N × TEST_POOL_SIZE` arithmetic does not
  see, addressed by decoupling in time rather than by inflating the budget
  formula (contrast with the ISS-0287 addendum's approach of widening the
  formula itself — not applicable here since inflating `TEST_POOL_SIZE`'s
  headroom cannot address a burst caused by a doubled, momentary pool-open,
  only a genuine time-domain fix can).
- `docs/issues/ISS-0219.yaml`, `docs/issues/ISS-0194.yaml` (full, resolved) —
  confirms AC4's exact wording ("N must derive only from a real signal ...
  never a hardcoded fallback") is scoped to `N`-derivation, not to how many
  partitions' startup phases may run concurrently — this design introduces a
  new, independent knob (`TEST_PARALLEL_MAX_CONCURRENT_CREATES`, §2) that
  gates concurrency of a phase, not the partition count itself, so it does
  not revisit or narrow AC4.
- `lib/letflow/design/iss0287-connection-pool-headroom-fix.md` (full) — used
  as this repo's own template/precedent for a `scripts/test_parallel.sh`
  budget-mechanism design doc's shape and citation discipline.
- `docs/anti-patterns.md` — no entry specific to shell concurrency-capping
  found; general "don't silently re-decide a locked AC" principle applied in
  §5.

---

## 1. Root cause (already diagnosed by ISSUE-FIXER — cited, not re-derived)

Restated from the dispatching handoff for this design's own traceability
(satisfies ISS-0698 AC(a) — root cause identified):

Step 2 backgrounds all `N` (16 on the measuring host) `mix test --partitions
N` processes in one loop with zero stagger. `mix.exs`'s `test:` alias makes
each process run `ecto.create --quiet` (cheap — a one-off maintenance
connection, not the app pool) then `ecto.migrate --quiet` (NOT cheap — calls
`Mix.Ecto.ensure_started/2`, which starts a full `Letflow.Repo` OTP
application at that process's own `TEST_POOL_SIZE`, i.e. opens a second,
distinct pool-lifecycle on top of whatever the later test phase itself opens)
before ever reaching the `test` step. All 16 processes reach this
`ecto.migrate`-triggered pool-open within the same narrow wall-clock window at
process-launch time, because nothing paces their starts — a transient demand
spike Step 1.5's clamp was never sized to cover (that clamp bounds
steady-state `N × TEST_POOL_SIZE` test-phase demand only, not a
launch-time-coincident extra pool-open per partition). Result: Postgres's
`max_connections=100` is exceeded transiently, and Postgres's own admission
control kills the losing connections with `53300 too_many_connections`,
observed as 12/16 partitions failing during `ecto.create`/`ecto.migrate`
("killed").

This is a distinct mechanism from every prior connection-budget issue this
decision record covers (ISS-0194's quadratic N×pool_size scaling, ISS-0287's
under-counted reserved/non-pooled connections, ISS-0515/0426's uncapped
nested-subprocess pool) — those are all steady-state or fixed-size
under-accounting; this one is a *launch-time synchronization* problem: `N`
processes independently doing the same two-pool-open sequence at the same
instant. No formula reslice of the existing clamp (as ISS-0287's addendum
did) can fix a synchronization problem — the fix has to change *when* the
`N` processes reach that pool-open, not *how big* any one pool is allowed to
be.

---

## 2. Fix shape: decouple and stagger the create/migrate phase from the
   parallel test launch (ISSUE-FIXER recommendation #1 — chosen)

### 2.1 Why this option over the other two recommended directions

- **Chosen: stagger/concurrency-cap the `ecto.create`+`ecto.migrate` phase,
  fully decoupled from the parallel test-phase launch.** Fixes the actual
  mechanism (N simultaneous pool-opens) at its source, touches only
  `scripts/test_parallel.sh`'s own Step 2 region (plus one narrow, opt-in
  `mix.exs` change explained in §3 — needed to make the decoupling real, not
  just cosmetic; see why below), does not touch `N`-derivation, does not
  reopen AC4.
- **Rejected as primary fix: give `letflow.check.test.ex` a default
  `TEST_PARALLEL_N`.** Would reduce `N` (e.g. to 4) for the automated
  invocation, shrinking the burst's magnitude, but doesn't fix the underlying
  synchronization defect — running `scripts/test_parallel.sh` directly (no
  `TEST_PARALLEL_N` override, the exact way ISS-0698 was discovered) would
  still hit the same failure at full `nproc`-derived `N` on any host with
  enough cores. Also flagged in ISS-0219's own resolution note as adjacent to
  a locked decision boundary. Not applied here; noted as a still-available
  belt-and-suspenders option if this fix alone proves insufficient (parallel
  to how 0009's ISS-0515 addenda layered fixes rather than replacing one with
  another).
- **Rejected as primary fix: raise Postgres `max_connections` alone.**
  Weakest alone per ISSUE-FIXER's own framing — doesn't fix the unbounded
  synchronized-burst structure, just raises the ceiling the same unbounded
  spike has to clear (precedent: 0009's ISS-0515 third-rework addendum tried
  exactly this in isolation for a different burst and it was insufficient by
  itself, only durable once layered under a real per-source fix). Left
  untouched here; still a legitimate belt-and-suspenders addition later if
  needed, not this fix's job.

### 2.2 New Step 1.7 — capped-concurrency pre-create/pre-migrate, inserted
   between existing Step 1.6 (build-path seeding) and Step 2 (parallel
   launch)

Insertion point: immediately after Step 1.6's `while` loop finishes (i.e.,
after all `N` `_build/test-partition-<i>` directories are seeded) and
immediately before Step 2's `tmp_dir=$(mktemp -d ...)` line. This mirrors
Step 1.6's own precedent of "a sequential/bounded per-partition setup pass
before the unbounded parallel launch."

For each partition `i` in `1..N`, run (as one background job per partition,
each job doing create-then-migrate sequentially *within itself*, jobs across
partitions capped in flight):

```
MIX_TEST_PARTITION=i MIX_BUILD_PATH=_build/test-partition-i mix ecto.create --quiet
  (only if exit 0) &&
MIX_TEST_PARTITION=i MIX_BUILD_PATH=_build/test-partition-i mix ecto.migrate --quiet
```

Concurrency across the `N` per-partition jobs is capped by a semaphore built
from bash's `wait -n` (bash 5.2 confirmed present; `wait -n` requires bash
≥4.3, already satisfied by this script's existing bash-not-sh choice) plus a
running-job counter, gated by a new env var:

- **`TEST_PARALLEL_MAX_CONCURRENT_CREATES`** (positive integer, default
  `4`) — max number of partitions allowed to be concurrently inside their own
  `ecto.create`+`ecto.migrate` pair at once. Validated with the same
  `grep -Eq '^[1-9][0-9]*$'` pattern this script already uses for
  `TEST_PARALLEL_N`/`TEST_MAX_CONNECTIONS`; `ERROR` + `exit 1` (no partition
  launched) if invalid, matching the script's existing fail-fast style for
  malformed numeric overrides.
  - **Default rationale:** independent of `N` and of `TEST_POOL_SIZE`'s own
    computed value (deliberately not derived from the Step 1.5 budget
    formula — that formula already governs steady-state `N × TEST_POOL_SIZE`
    demand; this cap governs a *different* axis, how many partitions may be
    mid-startup at once, and needs only to keep `cap × TEST_POOL_SIZE`
    comfortably under budget regardless of what `N` or `TEST_POOL_SIZE`
    happen to be). `4` matches ISS-0219's own documented known-good
    `TEST_PARALLEL_N` value for this host profile — reusing an
    already-verified-safe magnitude rather than inventing a new one.
  - Any partition whose `ecto.create`/`ecto.migrate` pair exits nonzero is a
    hard failure for the whole script: print which partition and its exit
    code, `exit 1` before Step 2 ever launches — mirrors Step 1's and Step
    1.6's existing "no partition launched" fail-fast contract. (Distinct from
    Step 4/5's later per-partition-tolerant aggregation, which only applies
    to *test* failures, not setup failures — setup failing for any partition
    means the run cannot proceed at all, same as a pre-compile failure
    today.)
  - **Semaphore mechanic and failure attribution (shape, not code) —
    resolved per CODE-DESIGN-VALIDATOR's rework request, option (a):**
    bare `wait -n` (no arguments) is explicitly NOT used, because it returns
    only the exit status of whichever background job finishes first and does
    not report *which* job that was — insufficient for this step's own "print
    which partition and its exit code" contract. Instead, use bash 5.1+'s
    `wait -n -p finished_pid` form (bash 5.2 confirmed present per §2.2's
    opening paragraph, comfortably above the 5.1 floor `-p` requires), plus an
    explicit PID→partition-index map maintained alongside the semaphore
    counter:
    - Declare `declare -A create_pid_to_partition` (an associative array,
      shape-parallel to Step 3's existing `pids[$i]`/`exits[$i]` indexed
      arrays, but keyed the other direction — by PID, not by partition index
      — because `wait -n -p` hands back a PID and the step needs to recover
      the partition index from it, not the reverse).
    - Before backgrounding partition `i`'s create-then-migrate job: if the
      in-flight count is already at `TEST_PARALLEL_MAX_CONCURRENT_CREATES`,
      call `wait -n -p finished_pid`, capture its exit status, look up
      `create_pid_to_partition[$finished_pid]` to recover which partition
      index just finished, remove that entry from the map, decrement the
      in-flight count, and treat a nonzero exit status the same as the
      hard-failure contract above (print the partition index recovered from
      the map, print the exit code, `exit 1`).
    - After backgrounding partition `i`'s job, record `$!` (its PID) as
      `create_pid_to_partition[$!]=i` and increment the in-flight count —
      this is the bookkeeping write that makes the later `wait -n -p` lookup
      possible.
    - After the launch loop, drain all remaining in-flight jobs the same way
      (repeated `wait -n -p finished_pid` + map lookup + nonzero check) until
      the map is empty — mirrors Step 3's own "wait for each partition
      individually" drain, adapted to PID-keyed lookup instead of
      index-keyed iteration since jobs finish in launch-order-agnostic order
      here (unlike Step 3, which waits on `pids[$i]` in a fixed `1..N` index
      order because Step 3 has no concurrency cap to enforce).
  - Log destination for this phase's output: reuse the same `tmp_dir`
    pattern as Step 2 but create it here — move both the existing
    `tmp_dir=$(mktemp -d ...)` line AND its immediately-following
    `echo "test_parallel: partition logs in $tmp_dir"` line up from Step 2
    into this new Step 1.7 (the echo moves with it, unchanged in wording —
    Step 1.7 is the step that now first needs `$tmp_dir` to exist, and the
    echo's own text already describes the directory generically enough
    — "partition logs in $tmp_dir" — that it need not be duplicated or
    reworded for the create-phase log files that will also land there).
    Step 1.7's own per-partition output goes to e.g. `$tmp_dir/create-$i.log`
    (a new naming convention alongside Step 2's existing
    `$tmp_dir/partition-$i.log`, both inside the same already-announced
    directory), so a setup failure's actual Postgrex/Mix error text is
    inspectable the same way Step 4 already makes test failures inspectable,
    without inventing a second `tmp_dir`/announcement mechanism. Step 2 no
    longer creates or announces `tmp_dir` itself (both lines are gone from
    Step 2, relocated in full to Step 1.7); Step 2 only continues to *use*
    the now-already-created `$tmp_dir` for its own `partition-$i.log` files.

### 2.3 Step 2 (launch), amended

Unchanged in structure (still one background `mix test --partitions N` job
per partition, still waited on individually in Step 3, still using the
per-partition `_build/test-partition-<i>` `MIX_BUILD_PATH`). The one addition:
every partition's launch command now also carries
`LETFLOW_SKIP_ECTO_SETUP=1` in its per-command env prefix (same style as the
existing `MIX_TEST_PARTITION`/`MIX_BUILD_PATH` per-command prefix — not a
global `export`, since — like `MIX_BUILD_PATH` — this only needs to be true
for these `mix test` invocations specifically, not for the `ecto.create`/
`ecto.migrate` calls Step 1.7 just ran without it):

```
MIX_TEST_PARTITION=i MIX_BUILD_PATH=_build/test-partition-i LETFLOW_SKIP_ECTO_SETUP=1 \
  mix test --partitions N --no-color $high_pool_demand_exclude "$@" \
  > "$tmp_dir/partition-i.log" 2>&1 &
```

This is why the `mix.exs` change in §3 is load-bearing, not optional: without
it, Step 2's `mix test` invocations still resolve through the unmodified
`test:` alias, which unconditionally runs `ecto.create --quiet` (harmless,
already-exists no-op) then `ecto.migrate --quiet` **again** — and it is
specifically that second `ecto.migrate` call's `ensure_started`-triggered
pool-open, run by all `N` processes at the same instant Step 2 backgrounds
them, that reintroduces the exact burst this design exists to eliminate. Pre-
running create/migrate in a capped Step 1.7 without also suppressing the
alias's redundant re-run in Step 2 would not fix ISS-0698 — it would only add
a second, harmless-looking phase in front of the same unfixed synchronized
burst.

---

## 3. `mix.exs` change (flagged for REVIEWER — narrow, opt-in, backward-
   compatible)

**Revision note (rework attempt 2):** this section previously proposed a
`test_alias/1` that *returns* a list of task-strings (relying on the same
self-reference-passthrough mechanism the existing static-list alias's
trailing `"test"` entry uses). ELIXIR-DEV attempted implementation and found,
verified live against this repo's actual toolchain (bash 5.2.37 / Mix 1.20.3
/ Elixir ~1.18 / Erlang OTP 29) in an isolated scratch Mix project, that this
does not work: for a **function**-based alias, Mix's `run_alias/6`
(`mix/lib/mix/task.ex` ~568-609) invokes the function for its side effects
only and **discards its return value** — `List.wrap(function)` wraps the
function itself as the sole list element, so nothing the function returns is
ever fed back into `run_task`/`do_run`. (The list-return convention only
applies to a **list**-based alias, where `List.wrap(alias)` yields the
task-strings directly.) Confirmed empirically: a function alias returning
`["test" | args]` ran nothing — not even the `test` step — and a deliberately
failing test under it exited `0` instead of `2`. The design below replaces
the return-a-list shape with the shape ELIXIR-DEV verified working live. OQ-1
(§7) is resolved by this same verification, not left open.

**What changes.** `defp aliases do ... end`'s `test:` entry converts from a
static list to a function:

```
test: &test_alias/1
```

with a new private function `test_alias/1` (shape, not implementation) that
calls `Mix.Task.run/2` directly for its side effects — it does **not**
return a list of task-strings:

- when `System.get_env("LETFLOW_SKIP_ECTO_SETUP") == "1"`: call
  `Mix.Task.run("test", args)` and stop — nothing else runs.
- otherwise (the default — env var unset, exactly today's behavior for every
  existing caller: plain `mix test`, CI, an editor's test runner, `iex -S mix
  test`, etc.): call, in order, `Mix.Task.run("ecto.create", ["--quiet"])`,
  then `Mix.Task.run("ecto.migrate", ["--quiet"])`, then
  `Mix.Task.run("test", args)` — three explicit calls, each a direct
  `Mix.Task.run/2` invocation, not a returned string list. This is the same
  three steps in the same order as today's static list
  (`["ecto.create --quiet", "ecto.migrate --quiet", "test"]`); ELIXIR-DEV
  must preserve default-branch behavior as byte-for-byte identical to today's
  alias (same tasks, same args, same order, same halt-on-nonzero-exit
  semantics `Mix.Task.run/2` already gives each step).

**Why this is safe and why the final `Mix.Task.run("test", args)` call does
not recurse.** This function *is* the resolution of the `"test"` alias
itself (Mix invokes `test_alias/1` precisely because it is registered under
the `test:` key). Calling `Mix.Task.run("test", args)` from inside it invokes
the real `test` task rather than re-entering alias resolution, because of
`Mix.TasksServer`'s alias-already-running guard (`task.ex` ~424-425): the
server tracks that the `test` alias is currently being resolved and, on
seeing `test` requested again from within that resolution, runs the
underlying task directly instead of looping back into the alias. ELIXIR-DEV
verified this live: a function alias calling `Mix.Task.run("test", args)`
directly correctly reached the real `test` task, including surfacing a
deliberately failing test correctly (`Result: 0/1 passed`, exit `2`).

**Why a function-based, env-gated alias rather than any other bypass.** Mix
aliases resolve by exact task name; there is no supported "invoke the
original task, skipping only the alias, from an unrelated call site" without
either (a) this env-gated self-reference trick, or (b) inventing a
differently-named alias/task purely to wrap the real `test` task, which is a
strictly bigger footprint (a new discoverable `mix` task most callers would
never know to use) for the same effect. (a) keeps the existing `mix test`
entry point and its default behavior completely unchanged for every caller
that doesn't set `LETFLOW_SKIP_ECTO_SETUP`.

**Scope discipline.** This is the same category of decision `docs/agents/
instructions/core-directives.md` asks not to silently make — it touches a
file outside `scripts/`, shared by every `mix test` caller in the repo, even
though its *default* behavior is provably unchanged (and now live-verified,
not just claimed — see OQ-1 resolution, §7). Per this task's own
instructions, still explicitly flagging for REVIEWER: REVIEWER should confirm
(1) the corrected mechanism above matches what ELIXIR-DEV implements
(`Mix.Task.run/2` calls, not a returned list) and that a live
`LETFLOW_SKIP_ECTO_SETUP=1 mix test` run skips `ecto.create`/`ecto.migrate`
output while a plain `mix test` run does not change at all; (2) that no other
`aliases` entry or CI step references `test:`'s static-list shape in a way a
function value would break (a grep-level check, not a design-level one).

---

## 4. Composition with the existing `TEST_POOL_SIZE` clamp (Step 1.5) —
   unchanged, explicitly

`TEST_POOL_SIZE` (Step 1.5's existing formula, all four `docs/migration/
decisions/0009-...md` addenda intact, none touched by this design) still
governs the pool size Ecto's `config/test.exs` reads for **both**:

- each partition's Step 1.7 `ecto.migrate` pool-open (now capped to at most
  `TEST_PARALLEL_MAX_CONCURRENT_CREATES` concurrent instances of that pool,
  §2.2), and
- each partition's Step 2 test-phase pool-open (still all `N` concurrent,
  exactly as today — this was already within the clamp's own accounted-for
  budget; ISS-0698 was never about the test-phase pool itself, only about an
  extra, unaccounted-for pool-open happening in the same instant as `N` of
  them).

No new arithmetic term is needed in the Step 1.5 formula — this design
removes a *synchronization* hazard, not a *budget-accounting* gap, so
`usable_ceiling`/`budget`/`computed_pool` (0009's existing formula, most
recently extended by its ISS-0515 addendum) are untouched. Worst-case
simultaneous demand after this fix: `max(TEST_PARALLEL_MAX_CONCURRENT_CREATES
× TEST_POOL_SIZE, N × TEST_POOL_SIZE)` — bounded by whichever phase is
active, never their sum, since Step 1.7 fully completes (all `N` databases
created+migrated) before Step 2 ever backgrounds a single test-phase process.
At this host's own numbers (`N`=16, `TEST_POOL_SIZE`=5,
`TEST_PARALLEL_MAX_CONCURRENT_CREATES`=4 default): Step 1.7's peak demand is
`4 × 5 = 20` connections (previously: `16 × 5 = 80`, all at once, colliding
with whatever else was live); Step 2's peak demand is unchanged at `16 × 5 =
80`, already within the existing clamp's accounted-for budget. Both phases
individually sit well inside `max_connections=100`.

---

## 5. `lib/mix/tasks/letflow.check.test.ex` — NOT touched, and why

ISSUE-FIXER's diagnosis noted this task never sets `TEST_PARALLEL_N`, making
ISS-0219's documentation-only remedy invisible to automated invocation — true,
but orthogonal to this design's fix. This design's mechanism (§2) does not
depend on `N` being small; it bounds concurrency of the *create/migrate*
phase independently of whatever `N` is derived to be, so it fixes the burst
at `N`=16 (this host's real, unmodified `nproc`-derived value) without
needing `letflow.check.test.ex` to override `N` at all. Giving it a default
`TEST_PARALLEL_N` remains a reasonable, independently-decidable follow-up
(§2.1's "not applied here" note) but is not required for ISS-0698's
acceptance criteria and is left alone here to keep this change minimal and
single-purpose, per this task's own instruction not to silently expand scope.

---

## 6. Acceptance-criteria mapping (`docs/issues/ISS-0698.yaml`)

- **(a) root cause identified.** §1, citing ISSUE-FIXER's Step 1 diagnosis
  directly (two-pool-lifecycles-per-partition, all `N` synchronized at
  launch) — not re-derived, restated for this design's own traceability.
- **(b) full 16-way run reliably creates all 16 partition DBs without 53300
  errors.** §2.2's capped Step 1.7 bounds concurrent `ecto.migrate`
  pool-opens to `TEST_PARALLEL_MAX_CONCURRENT_CREATES` (default 4) instead of
  `N` (16), and §2.3/§3 ensure Step 2 never redundantly re-triggers that same
  pool-open a second time in an uncapped burst. §4's arithmetic shows both
  phases' peak demand individually well under `max_connections=100` at this
  host's real numbers.
- **(c) supports a regression proof — full `mix letflow.check.test` run
  completing with all 16 partitions producing a `Result:` line.**
  `letflow.check.test.ex`'s log-discovery contract (reads
  `test_parallel: partition logs in <dir>` then every `partition-*.log`)
  is unchanged by this design (§5) — Step 2 still produces exactly `N`
  `partition-<i>.log` files with the same naming convention, now free of the
  53300 crash mode, so a live `mix letflow.check.test` (or direct
  `scripts/test_parallel.sh`) run is the natural regression proof: TEST-
  RUNNER re-runs it and confirms all 16 partitions reach a `Result:` line
  with zero `too_many_connections` occurrences across
  `create-*.log`/`partition-*.log`.

---

## 7. Open questions (explicit — not silently resolved)

- **OQ-1 — RESOLVED (rework attempt 2), no longer open.** Originally: the
  self-reference alias-passthrough mechanism §3 relies on for the `mix.exs`
  change was a documented-but-unexecuted Mix behavior claim. ELIXIR-DEV
  attempted implementation against the original (return-a-list) shape and
  found it does not work — a function-based alias's return value is discarded
  by Mix's `run_alias/6` (`mix/lib/mix/task.ex` ~568-609); only a
  list-based alias's return value is walked as task-strings. ELIXIR-DEV
  live-verified, in an isolated scratch Mix project against this repo's real
  toolchain (bash 5.2.37 / Mix 1.20.3 / Elixir ~1.18 / Erlang OTP 29), the
  corrected shape now in §3: a function alias that calls `Mix.Task.run/2`
  directly (not returning a list) does reach the real `test` task via
  `Mix.TasksServer`'s alias-already-running guard (`task.ex` ~424-425),
  confirmed with a deliberately failing test surfacing correctly (`Result:
  0/1 passed`, exit `2`). §3 has been updated to this verified mechanism; no
  further live-verification gate remains before ELIXIR-DEV re-attempts
  implementation, though REVIEWER's §3 checklist (grep for other `test:`
  references, confirm default-branch byte-for-byte parity) still applies.
- **OQ-2:** `TEST_PARALLEL_MAX_CONCURRENT_CREATES`'s default of `4` is
  reasoned from ISS-0219's precedent value, not from a formula tied to this
  host's actual `max_connections`/`TEST_POOL_SIZE` the way Step 1.5's clamp
  is. If a future host's real budget is tighter than this default assumes
  (e.g. a much smaller `max_connections`), the same class of burst could
  reappear at the *create* phase even after this fix, at a smaller scale —
  left as a known limitation rather than over-engineered into a second
  formula, since ISS-0698's own evidence is one host's real numbers and a
  fixed, previously-verified-safe default directly addresses it; a future
  issue can extend this knob into a formula the same way 0009's addenda
  extended the pool-size clamp, if real evidence calls for it.
- **OQ-3:** whether `ecto.create`'s own maintenance-connection behavior
  (confirmed cheap/one-off per §1, not the app pool) ever changes across an
  Ecto/Postgrex version bump is not verified here — if a future dependency
  bump made `ecto.create` itself start the full pool (unlike today), Step
  1.7's per-partition job already runs it inside the same capped semaphore as
  `ecto.migrate` (§2.2), so this design's cap would still bound it; flagged
  only so a future reader does not assume `ecto.create`'s cheapness was
  re-verified as part of this specific change.
