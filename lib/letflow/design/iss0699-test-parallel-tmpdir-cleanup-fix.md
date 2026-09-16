# ISS-0699 — `scripts/test_parallel.sh` `tmp_dir` cleanup-on-exit fix design

**Status:** design, not yet implemented.
**Run:** WF03-ISS0699-20260917, branch `feature/WF03-ISS0699-20260917`.
**Scope:** `scripts/test_parallel.sh` only — the `tmp_dir` created at Step 1.7
(line 245) and every exit path from that point onward. No implementation code
below — trap registration point, cleanup-function shape/pseudocode, env-var
contract, and an explicit exit-path-by-exit-path disposition table only.
**Explicitly out of scope:** everything ISS-0698's own design
(`lib/letflow/design/iss0698-test-parallel-create-burst-fix.md`) already
settled for this script — `N`-derivation, the `TEST_POOL_SIZE` clamp, the
Step 1.7 capped-concurrency create/migrate mechanism itself, the `mix.exs`
`test:`-alias change, and the Step 4/5 log-parsing/exit-code contract. This
design only adds cleanup of the directory those steps already create and
write into; it does not change what gets written into it, when, or by whom.

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
  ELIXIR-DEV.

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
