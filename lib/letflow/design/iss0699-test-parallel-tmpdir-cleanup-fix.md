# ISS-0699 — `scripts/test_parallel.sh` `tmp_dir` cleanup-on-exit fix design

**Status:** design, revised (REWORK ITERATION 1) — not yet implemented.
**Run:** WF03-ISS0699-20260917, branch `feature/WF03-ISS0699-20260917`.
**Scope:** `scripts/test_parallel.sh`'s `tmp_dir` cleanup mechanism (§1-§3,
unchanged from iteration 0) **plus** — new in this revision —
`lib/mix/tasks/letflow.check.test.ex`'s coordination with that mechanism as
its one downstream consumer that reads `tmp_dir` after the script exits
(§3a). No implementation code below — trap registration point, cleanup-
function shape/pseudocode, env-var contract, exit-path disposition table,
and exact call-site/insertion-point pseudocode for the caller-side change
only.
**Explicitly out of scope:** everything ISS-0698's own design
(`lib/letflow/design/iss0698-test-parallel-create-burst-fix.md`) already
settled for this script — `N`-derivation, the `TEST_POOL_SIZE` clamp, the
Step 1.7 capped-concurrency create/migrate mechanism itself, the `mix.exs`
`test:`-alias change, and the Step 4/5 log-parsing/exit-code contract. This
design only adds cleanup of the directory those steps already create and
write into; it does not change what gets written into it, when, or by whom.
The ISS-0069 warning-substring check itself
(`@target_substring`/`check_substring_across_logs/1`/`find_partition_log_dir/1`
in `letflow.check.test.ex`) is also out of scope and is confirmed untouched
by this revision — see §3a.4.

---

## REWORK ITERATION 1 — why this revision exists

Iteration 0's design (§1-§3 below, unchanged) reasoned only about
`scripts/test_parallel.sh`'s own internal exit paths. It shipped, passed
CODE-DESIGN-VALIDATOR and every downstream gate, and then failed CI at Step
Final's git-merge run: `lib/mix/tasks/letflow.check.test.ex` — the `mix
letflow.check.test` task CI's backend gate runs — shells out to
`scripts/test_parallel.sh` via `stream_and_capture/2` (`run_main_suite/0`,
current line 169), waits for it to exit, and only *then* reads that same
`tmp_dir`'s `partition-*.log` files (via the runner's own printed
`"test_parallel: partition logs in <dir>"` line, parsed by
`find_partition_log_dir/1` and consumed in `check_main_suite_logs/2`) to
apply the ISS-0069 substring gate — on **every** run, not just a failing
one. Iteration 0's success-only cleanup trap deletes `tmp_dir` before this
external caller ever gets to read it, so CI's backend job hard-failed on
every clean run with `"partition log directory ... contains zero
partition-*.log files"`. Full evidence:
`handoffs/WF03-ISS0699-20260917/step-final-git-merge.json`'s
`result.summary`/`result.issues` (Step Final's PR #1469 CI run).

This revision (§3a) keeps §1-§3's script-side mechanism entirely as
designed — ISS-0699 (unbounded accumulation on direct/manual invocation of
the script) is still fixed by it — and adds the missing piece: how
`letflow.check.test.ex`, as a caller that legitimately needs `tmp_dir` to
survive past the script's own exit, coordinates with the trap instead of
racing it.

---

## 0. Sources read for this design

- ISSUE-FIXER's diagnosis, `result.summary` of
  `handoffs/WF03-ISS0699-20260917/step-01-issue-fixer-diagnosis.json` (full,
  quoted/restated where load-bearing below — not re-derived independently;
  the exit-line numbers and recommendation below are ISSUE-FIXER's, cited).
- `scripts/test_parallel.sh` (full, current state, 456 lines) — confirmed
  directly: `tmp_dir=$(mktemp -d ...)` at line 245, no `trap` anywhere in the
  file (grepped), and no `rm -rf "$tmp_dir"` on any path.
- `lib/letflow/design/iss0698-test-parallel-create-burst-fix.md` (full) — used
  as this repo's own template for this design doc's shape, and as the source
  of the current line numbers/step structure (Step 1.7 inserted by ISS-0698,
  now the step whose output this design cleans up).
- `docs/anti-patterns.md` — no entry specific to bash trap/cleanup patterns;
  general "don't silently re-decide a locked tradeoff" principle applied in
  §2 (ISSUE-FIXER's recommendation is adopted, not re-litigated).
- **Added in REWORK ITERATION 1:**
  `handoffs/WF03-ISS0699-20260917/step-final-git-merge.json` (full,
  `result.summary`/`result.issues` — the CI failure evidence this revision
  fixes) and `lib/mix/tasks/letflow.check.test.ex` (full, current state,
  804 lines) — confirmed directly: `run_main_suite/0` (lines 159-198) is
  the only call site invoking `scripts/test_parallel.sh` (line 169), via
  `stream_and_capture/2` (lines 780-792, currently 2-arity, no env-var
  passthrough), and `check_main_suite_logs/2` (lines 226-266) is the sole
  reader of `log_dir`'s `partition-*.log` files, called once from the
  `{:ok, log_dir}` branch (line 196).

---

## 1. Root cause (already diagnosed by ISSUE-FIXER — cited, not re-derived)

Restated for this design's own traceability: `tmp_dir=$(mktemp -d
"${TMPDIR:-/tmp}/letflow_test_parallel.XXXXXX")` at line 245 is never removed
on any of the script's exit paths. No `trap` is set anywhere in the file. The
dominant leak is the script's own single normal-completion exit at line 455
(`exit "$any_failed"`), reached on every run regardless of pass/fail — this
alone produced the ~280 accumulated `/tmp/letflow_test_parallel.*`
directories ISS-0699 observed. Three earlier `exit 1` paths (lines 251, 268,
291 — all inside or after Step 1.7, which creates `tmp_dir` at line 245) leak
it too, but two of those (268, 291) currently do useful work by leaking:
their own error message text cites `$tmp_dir/create-$finished_partition.log`
by path for a human/agent to inspect after a setup failure, and this
pipeline's other workflows (TEST-RUNNER reports etc.) are independently
confirmed to rely on citing a specific `partition-N.log` path after a failing
run. See ISSUE-FIXER's diagnosis for the full per-line walk; not re-derived
here.

---

## 2. Fix shape: success-only cleanup via a single `trap ... EXIT`, opt-out
   env var layered on top (ISSUE-FIXER's recommendation — adopted as-is)

### 2.1 Why this option, not the alternatives

- **Chosen: `trap` a cleanup function on `EXIT`, registered immediately after
  `tmp_dir`'s creation; the cleanup function inspects the exit code and
  removes `tmp_dir` only when it is `0` (clean run) and the new opt-out env
  var is not set.** A single registration point at line 245-246 covers every
  exit path from that point forward — lines 251, 268, 291, and 455 — without
  editing each of the four call sites individually. This is the same "one
  mechanism, not N call-site edits" property ISS-0698's own Step 1.7 semaphore
  design favored for its own concurrency cap.
- **Rejected: unconditional cleanup on every exit (no exit-code check).**
  Directly contradicted by ISSUE-FIXER's diagnosis — lines 268/291's own
  error messages cite the log path they'd be deleting, and this pipeline's
  other workflows are independently confirmed to depend on that path
  surviving a failing run for inspection. Would trade the disk-growth bug for
  a lost-evidence bug. Not used.
- **Rejected: per-call-site `rm -rf "$tmp_dir"` edits at each of the four exit
  points instead of a trap.** Functionally equivalent in principle but
  requires editing four separate locations (three of them are bare `exit 1`
  statements that would each need to grow an `rm -rf` line in front of them)
  and is fragile against a future fifth exit path being added without the
  same discipline. A single `trap` registered once cannot be forgotten by a
  future edit that adds another `exit` call after line 245. Not used.

### 2.2 Trap registration — exact point and shape

Registered as the line immediately following the existing `tmp_dir=$(mktemp
-d ...)` line (current line 245), before the existing `echo "test_parallel:
partition logs in $tmp_dir"` line (current line 246) or immediately after it
— either ordering is acceptable since neither statement can itself fail in a
way that matters, but the trap must be registered before line 248's
`TEST_PARALLEL_MAX_CONCURRENT_CREATES` validation (the first exit path that
needs to be covered).

Registration line (shape, this is the actual one-line statement — trivial
enough that stating it is not "implementation code" in the sense this
project's no-code rule means, the same way ISS-0698's design stated exact
env-var-read lines):

```
trap cleanup_tmp_dir EXIT
```

No signal list beyond `EXIT` is needed: bash's `EXIT` pseudo-trap fires on
every way the script terminates from this point on that this script actually
uses — an explicit `exit N` call (all four paths in scope: 251, 268, 291,
455) and falling off the end of the script (not applicable here since line
455 is the last line and always calls `exit` explicitly, but harmless to
have covered). `set -u` (already in effect, line 70) does not itself cause an
exit and needs no separate signal; nothing in this script traps `ERR` or
relies on `set -e`, so no interaction with either.

### 2.3 Cleanup function — exact shape/pseudocode

Defined once, before the trap is registered (i.e., placed above line 245 —
natural placement is directly above the Step 1.7 comment block, since it's
the step that first needs it), pseudocode:

```
cleanup_tmp_dir() {
  local exit_code=$?          # MUST be the function's first statement —
                               # capturing $? here is what recovers the
                               # script's own real exit status (0, or
                               # whatever N was passed to `exit N`); any
                               # earlier statement would clobber it before
                               # it can be read.

  if [ "$exit_code" -eq 0 ] && [ -z "${TEST_PARALLEL_KEEP_LOGS:-}" ]; then
    rm -rf "$tmp_dir"
  else
    echo "test_parallel: preserving $tmp_dir (exit_code=$exit_code, TEST_PARALLEL_KEEP_LOGS=${TEST_PARALLEL_KEEP_LOGS:-unset})" >&2
  fi
}
```

Notes on this shape (design-level constraints ELIXIR-DEV's implementation
must satisfy, not the literal ready-to-paste function body):

- `local exit_code=$?` must be the first statement in the function body —
  bash sets `$?` to the trap's own triggering status only for the window
  before the trap handler runs its first command; any command executed
  first (even a no-op `echo` for debugging) would overwrite it.
- The check is `-eq 0`, not "no error message was printed" or any other
  proxy — `$any_failed` (line 455's argument) is already the script's own
  authoritative pass/fail signal per Step 5's existing exit-code contract
  (see script's own Step 5 comment, "the parsed failure count ... is the
  authoritative success signal"); reusing raw exit code here composes
  correctly with that contract without needing a second, parallel status
  variable.
- `$tmp_dir` is already in scope as a plain (non-`local`) shell variable set
  at the script's top level (line 245) — the function reads it as a global,
  consistent with how the rest of the script already reads other top-level
  variables (`$N`, `$TEST_POOL_SIZE`, etc.) from inside its `while` loops
  without passing them as arguments.
- The preserved-path branch's message is stderr (`>&2`), matching every
  other diagnostic/warning line already in this script (e.g. line 175, line
  416), and is purely informative — it does not change the exit code the
  trap fires with; bash preserves the pre-trap exit status as the script's
  final exit status by default as long as the trap handler itself does not
  call `exit` with a different code (this cleanup function must not call
  `exit` at all, for exactly that reason).

### 2.4 New opt-out env var — `TEST_PARALLEL_KEEP_LOGS`

- **Name:** `TEST_PARALLEL_KEEP_LOGS`.
- **Default:** unset (falsy) — default behavior is the new success-only
  cleanup described above; no caller needs to change anything to get the
  fix.
- **Semantics:** when set to any non-empty value (checked with `[ -z
  "${TEST_PARALLEL_KEEP_LOGS:-}" ]`, the same "is it non-empty" idiom this
  script already uses at line 75 for `TEST_PARALLEL_N`, rather than a strict
  `= "1"` equality check — consistent with the rest of this script's env-var
  truthiness style, which treats presence/non-emptiness as the on-signal, not
  a specific literal string), forces preservation of `tmp_dir` even on a
  fully clean (`exit_code -eq 0`) run — for a caller who wants to inspect a
  clean run's timing/logs too, per ISSUE-FIXER's recommendation.
  Deliberately not validated against a numeric pattern (unlike
  `TEST_PARALLEL_N`/`TEST_MAX_CONNECTIONS`/etc.) since it is a pure
  presence/boolean flag, not a numeric knob — no malformed-value failure mode
  exists for it to guard against.
- No new fail-fast validation branch is needed for this var, unlike
  `TEST_PARALLEL_MAX_CONCURRENT_CREATES` (line 248-252) — an unset or
  arbitrary non-empty value are both valid, unambiguous inputs.

---

## 3. Exit-path disposition table (every path ISSUE-FIXER identified,
   explicit keep/remove and why)

| Line (current) | Trigger | `exit_code` seen by trap | Disposition under this design | Why |
|---|---|---|---|---|
| 251 | `TEST_PARALLEL_MAX_CONCURRENT_CREATES` malformed | 1 | **Preserved** | Nonzero exit code — falls into the `else` branch of §2.3 unconditionally. `tmp_dir` at this point contains nothing yet (created one line earlier, before any log is written) but preservation is harmless and keeps the policy uniform — no special-casing "empty tmp_dir" needed. |
| 268 | Partition create/migrate fails in the capped-wait branch of Step 1.7's launch loop | 1 | **Preserved** | Nonzero exit code. This is exactly the case ISSUE-FIXER flagged as load-bearing: the error message on this same line already cites `$tmp_dir/create-$finished_partition.log`; preserving it keeps that citation valid and inspectable. |
| 291 | Partition create/migrate fails in the post-loop drain | 1 | **Preserved** | Same reasoning as 268 — same error-message shape, same load-bearing log citation. |
| 455, `any_failed=0` | Normal completion, all partitions clean | 0 | **Removed** (unless `TEST_PARALLEL_KEEP_LOGS` is set) | This is the dominant leak path ISSUE-FIXER identified (every successful run leaked one directory, producing the ~280 accumulated dirs). Exit code 0, no `TEST_PARALLEL_KEEP_LOGS` override — first branch of §2.3 fires, `tmp_dir` is removed. |
| 455, `any_failed=1` | Normal completion, real test failures present | 1 | **Preserved** | Nonzero exit code — `else` branch of §2.3. This is the case Step 4's own per-partition `Result:`/`Failed:` parsing and TEST-RUNNER's downstream log inspection depend on; preserving it is required, not incidental. |

Every path in scope (all four ISSUE-FIXER named) is covered by the single
trap registered once in §2.2 — no per-line edit is needed at 251, 268, 291,
or 455 themselves beyond what ISS-0698 already put there.

**Caveat added in this revision:** the table above states the *default*
disposition — no caller opts into preservation. §3a below describes one
specific caller, `letflow.check.test.ex`, that always sets
`TEST_PARALLEL_KEEP_LOGS` when it invokes this script, which changes every
row's disposition to "preserved" *for that caller's invocations only* (the
env var is process-scoped to that one subprocess; a direct/manual
invocation of the script by anyone else is completely unaffected and still
gets the table above verbatim). This is not a new disposition rule — it is
§2.4's existing opt-out semantics, exercised by a specific, new caller.

---

## 3a. Caller coordination — `lib/mix/tasks/letflow.check.test.ex` (new in
   REWORK ITERATION 1)

### 3a.1 Why the caller, not the trap, must change

The trap (§2) cannot distinguish "a human ran this script directly and
doesn't need `tmp_dir` afterward" from "`letflow.check.test.ex` ran this
script and needs `tmp_dir` for another ~seconds until it finishes reading
partition logs" — both look identical from inside the script: a clean exit
code 0. The trap has no visibility into whether an external reader is about
to open the directory it's about to delete. Only the caller knows it still
needs the directory, so the caller must be the one to say so (via the
existing opt-out env var, §2.4) and the one to clean up afterward (since
the script, having handed off ownership via the opt-out, no longer will).
This is exactly the shape the original REWORK dispatch recommended
evaluating, and this design adopts it as-is — no alternative shape was
found preferable (see §3a.5).

### 3a.2 Change 1 — `run_main_suite/0` sets `TEST_PARALLEL_KEEP_LOGS=1` on
   its own invocation of the script

**Exact call site:** `run_main_suite/0` (current lines 159-198), the single
`stream_and_capture(bash, ["scripts/test_parallel.sh"])` call at current
line 169. This is the only call site in the whole module that invokes
`scripts/test_parallel.sh` — the module's three other `stream_and_capture`
call sites (`run_discovery_dry_run/0` line 493, `run_single_wasm_hang_test/1`
line 688, `run_lua_wallclock_race_tests/0` line 725) invoke plain `mix
test ...` subprocesses, never the script, and must NOT get this env var —
they have no `tmp_dir`/log-dir concept at all, so setting it on them would
be a no-op at best and confusing at worst. Scope the change to line 169
only.

**Mechanism:** `stream_and_capture/2` (current lines 780-792) does not
currently accept or forward any environment variables to the `Port.open/2`
call at line 783 — its `opts` list is a fixed literal (`:binary,
:exit_status, :stderr_to_stdout, args: args`). This design adds a third,
optional argument, `env \\ []`, threaded into an `:env` entry in that opts
list:

```
defp stream_and_capture(cmd, args, env \\ [])
```

Pseudocode shape for the opts list (illustrating the *addition*, not a
full rewrite of the existing function — the `:binary`/`:exit_status`/
`:stderr_to_stdout`/`args:` entries are unchanged):

```
Port.open({:spawn_executable, executable}, [
  :binary, :exit_status, :stderr_to_stdout,
  args: args,
  env: env            # NEW — [] by default, same as calling Port.open
])                     # with no :env key at all (Erlang's :env option only
                       # *adds/overrides* the named vars on top of the
                       # invoking process's own inherited environment; it
                       # does not replace the environment wholesale, so an
                       # empty list changes nothing for the three existing
                       # non-script call sites once they're updated to the
                       # new 3-arity signature with no env argument, or an
                       # explicit `[]`).
```

`run_main_suite/0`'s own call site becomes (shape, not literal Elixir —
exact charlist-vs-binary typing for the env tuple's key/value per Erlang's
port `:env` option is an implementation detail for ELIXIR-DEV to confirm
against the Erlang docs/a live test, not dictated here):

```
stream_and_capture(bash, ["scripts/test_parallel.sh"],
  [{"TEST_PARALLEL_KEEP_LOGS", "1"}])
```

The other three call sites (lines 493, 688, 725) are left as plain 2-arity
calls (`env` defaults to `[]`), unchanged in behavior.

### 3a.3 Change 2 — `check_main_suite_logs/2` (or its call site) becomes
   responsible for removing `log_dir` once done reading it, on every path

**Exact insertion point:** wrap the existing call to `check_main_suite_logs/2`
inside `run_main_suite/0`'s `{:ok, log_dir} -> check_main_suite_logs(...)`
branch (current line 196) in a `try ... after` that unconditionally removes
the resolved native log directory once `check_main_suite_logs/2` returns
*or raises*:

```
{:ok, log_dir} ->
  native_log_dir = resolve_native_path(log_dir)

  try do
    check_main_suite_logs(native_log_dir, exit_code)
  after
    File.rm_rf!(native_log_dir)
  end
```

This placement (wrapping the call site, not editing inside
`check_main_suite_logs/2`'s own body) is chosen because it covers every one
of that function's four internal outcomes with a single `after` block,
matching this whole design's existing "one mechanism over N call-site
edits" preference from §2.1:

  - the `[]` (zero partition logs found) branch, which `Mix.raise`s;
  - the `exit_code != 0` branch, which calls `report_partition_failures/1`
    (reads every log's content) and then `Mix.raise`s;
  - the `{:offending, offending}` branch (ISS-0069 substring found), which
    `Mix.raise`s after formatting the offending lines;
  - the `:ok` branch, which returns normally after `Mix.shell().info/1`.

`Mix.raise/1` raises a normal `Mix.Error` exception (it does not call
`System.halt/1` or otherwise bypass Elixir's exception mechanism) — an
Elixir `try/after` block's `after` clause runs on both a normal return and
a raised exception, so all four branches above are covered by the single
`after File.rm_rf!(native_log_dir) end`, with no branch needing its own
explicit cleanup call. `File.rm_rf!/1` (not `File.rm_rf/1`) is used so a
cleanup failure itself (e.g. a permissions problem) surfaces loudly rather
than being silently swallowed — consistent with this module's existing
"never silently pass" discipline (moduledoc, "hard-fails ... rather than
silently passing", repeated at three separate points in the existing
module).

Note: `resolve_native_path/1` (current lines 209-224) is already called
once inside `check_main_suite_logs/2`'s caller context today — actually it
is called directly at the `{:ok, log_dir} ->` branch already (current line
196: `check_main_suite_logs(resolve_native_path(log_dir), exit_code)`), so
this design's pseudocode above simply lifts that existing call out one
level (into a `native_log_dir` binding) so the same resolved path is
available to both the `try` body and the `after` cleanup — it does not add
a second, redundant path-resolution call.

### 3a.4 ISS-0069 substring-check logic — confirmed untouched

`@target_substring`, `@log_dir_line_regex`, `find_partition_log_dir/1`,
`partition_logs/1`, `index_partition_logs/1`,
`check_substring_across_logs/1`, and `report_partition_failures/1` are not
referenced anywhere in §3a.2 or §3a.3 above and need no edits. §3a.2 only
touches `stream_and_capture/2`'s signature and `run_main_suite/0`'s one
call to it; §3a.3 only wraps an existing call to `check_main_suite_logs/2`
from the outside, after that function's own body (including the substring
check inside it) has already fully run. The substring check reads
`log_dir`'s content *before* the new `after` block's `File.rm_rf!/1` can
possibly run (Elixir evaluates the `try` body to completion — including
every nested function call inside `check_main_suite_logs/2` — before its
`after` clause fires), so the ordering guarantee this whole fix depends on
(read-before-delete) holds by construction, not by timing luck.

### 3a.5 Alternative shapes considered and rejected

- **Delay-only (no env var, just have the script wait/not clean up until
  some external signal):** rejected — would need a new IPC/signaling
  mechanism between the bash script and its Elixir caller (a lock file, a
  second env var the script polls, etc.), strictly more complex than
  reusing the opt-out env var §2.4 already designed for exactly this
  "a caller wants to keep the logs" case. Not used.
- **Have `letflow.check.test.ex` copy the partition logs to a location it
  owns before the script's trap can delete them, instead of suppressing the
  trap:** rejected — the trap fires in the script's own `EXIT` handler,
  which runs synchronously before `stream_and_capture/2`'s
  `Port.open/2` call in the Elixir side even observes the subprocess exit;
  there is no window in which the Elixir side could copy files out of
  `tmp_dir` after the script exits but before the trap has already deleted
  them, since the trap deletion happens inside the same OS process that
  is generating the exit status the Elixir side is waiting on. Not used.
- **Recommended shape from the REWORK dispatch (env var opt-out on the
  script side + caller-owned cleanup, §3a.2/§3a.3 above):** adopted as-is —
  no signaling race, reuses the mechanism already designed in §2.4, and
  keeps `letflow.check.test.ex`'s own tmp-dir accumulation bounded
  end-to-end (every invocation, success or failure, now removes its own
  `log_dir` exactly once via the `try/after`).

---

## 4. Composition with existing script behavior — unchanged, explicitly

- Step 1.7's own per-partition failure messages (lines 268, 291) are
  unchanged in wording — they already cite `$tmp_dir/create-$i.log`; this
  design makes that citation reliably survive to the point a human/agent
  reads it, it does not change the message text.
- Step 4/5's exit-code contract (`any_failed`, line 455) is unchanged — this
  design reads that same value (via `$?` in the trap, which equals whatever
  `exit "$any_failed"` passed) but does not alter how `any_failed` itself is
  computed.
- `set -u` (line 70) is unaffected — `${TEST_PARALLEL_KEEP_LOGS:-}` and
  `${exit_code}` (a `local` always assigned before use) are both
  unset-safe reads in the existing style already used throughout this script
  (e.g. `${TMPDIR:-/tmp}` at line 245 itself).

---

## 5. Acceptance-criteria mapping (this handoff's own criteria)

- **Design doc created at the specified path.** This file.
- **Exact trap mechanism and registration point.** §2.2 — `trap
  cleanup_tmp_dir EXIT`, registered immediately after `tmp_dir=$(mktemp -d
  ...)` (current line 245), before the first exit path that needs coverage
  (line 251).
- **Opt-out env var name, default, semantics.** §2.4 — `TEST_PARALLEL_KEEP_LOGS`,
  default unset (cleanup-on-success is the default behavior), any non-empty
  value forces preservation even on a clean exit.
- **Every exit path's keep/remove disposition, explicit.** §3's table —
  lines 251, 268, 291 preserved; line 455 removed when `any_failed=0`,
  preserved when `any_failed=1`.
- **No finished, ready-to-paste script implementation.** §2.3's function body
  and §2.2's registration line are stated as the trap/function *shape* this
  task's own dispatching instructions explicitly asked for ("the trap's exact
  shape and the cleanup function's exact shape/pseudocode ... is necessary
  here since there is no @spec-equivalent for bash to design against") — the
  surrounding script edits (where exactly to splice these lines into the
  existing file, whether to adjust comments elsewhere, etc.) are left to
  ELIXIR-DEV. §3a's pseudocode is likewise shape-only (an added `env`
  parameter, an added opts entry, a `try/after` wrapping an existing call) —
  not a finished diff of `letflow.check.test.ex`.
- **REWORK ITERATION 1 — `letflow.check.test.ex` coordination.** §3a.2 states
  the exact env var (`TEST_PARALLEL_KEEP_LOGS`, already named/defaulted in
  §2.4) and the exact point it is set — `run_main_suite/0`'s one
  `stream_and_capture` call at current line 169, via a new optional `env`
  argument on `stream_and_capture/2` (→ `/3`). §3a.3 states the exact point
  `log_dir` is now removed by the caller — a `try/after` wrapped around the
  existing `check_main_suite_logs(native_log_dir, exit_code)` call at
  current line 196, covering all four of that function's outcomes (empty
  logs, real failures, ISS-0069 offending substring, clean `:ok`) with one
  `File.rm_rf!/1` in the `after` clause.
- **REWORK ITERATION 1 — ISS-0069 substring-check logic confirmed
  untouched.** §3a.4 — no edit to `@target_substring`,
  `@log_dir_line_regex`, `find_partition_log_dir/1`, `partition_logs/1`,
  `index_partition_logs/1`, `check_substring_across_logs/1`, or
  `report_partition_failures/1`; the read-before-delete ordering this fix
  depends on holds by Elixir's own `try/after` evaluation order, not by
  timing luck.

---

## 6. Open questions (explicit — not silently resolved)

- **OQ-1 (flagged by ISSUE-FIXER, not resolved here):** success-only cleanup
  does not, by itself, bound disk accumulation from repeated *failing* runs
  — a host with a flaky/red suite could still accumulate many
  preservation-triggered directories over time. A secondary bound (e.g.
  pruning failure-preserved `letflow_test_parallel.*` directories older than
  N days at script start) was raised by ISSUE-FIXER as worth considering but
  explicitly left as a design decision rather than dictated. Not designed
  here — left as a follow-up, same as ISS-0698's own OQ-2/OQ-3 pattern of
  flagging a known limitation without over-engineering a fix the filed issue
  doesn't require. If adopted later, it would need its own env-var/default
  and would compose with, not replace, the mechanism in §2.
- **OQ-2:** whether `TEST_PARALLEL_KEEP_LOGS` should also be documented in
  the script's own top-of-file comment block (alongside `TEST_PARALLEL_N`
  etc., lines 41-53) is left to ELIXIR-DEV's implementation — this design
  specifies the var's contract but not the exact comment-block wording,
  consistent with "signatures/shapes, not the literal file edit" per this
  task's own scope.
- **OQ-3 (new in REWORK ITERATION 1):** §3a.2's env-tuple value type
  (`{"TEST_PARALLEL_KEEP_LOGS", "1"}` as plain Elixir binaries vs. charlists)
  for Erlang's `Port.open/2` `:env` option is left for ELIXIR-DEV to confirm
  against the Erlang `erlang:open_port/2` docs (or a live test) at
  implementation time — this design fixes the semantics (which var, which
  value, which one call site) but not this one FFI-boundary typing detail,
  since it does not change any of this design's own reasoning (§3a.2-§3a.4)
  regardless of which representation is correct.
