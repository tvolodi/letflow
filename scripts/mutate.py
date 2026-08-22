#!/usr/bin/env python3
"""
scripts/mutate.py -- single-occurrence substitution mutation-testing helper.

Applies one textual substitution mutant to a target file, runs a test
command against the mutated file, reports whether the mutant was KILLED
(the command exited non-zero -- some test caught the mutation) or
SURVIVED (the command exited zero -- nothing detected it), then
unconditionally reverts the file to its exact original content and
verifies the revert.

ORIGIN
  Reconstructed and generalised from `tdv_mutate.py`, a throwaway script
  TEST-DESIGN-VALIDATOR wrote and deleted during WF03-ISS0258-20260822
  (docs/issues/ISS-0258.yaml; the original's interface and single-
  occurrence guard are described verbatim in
  handoffs/WF03-ISS0258-20260822/step-04b-test-design-validator.md,
  section 7). That script only applied the guarded substitution --
  running the tests and reverting were separate shell commands repeated
  by hand in every WF-03 mutation pass. This version does apply -> run
  -> report -> revert as one command, and the revert always runs, even
  if the test command errors or the process is interrupted
  (try/finally), so leaving a mutant in the tree by accident -- the
  exact hazard WF-03's own mutant-isolation section warns about --
  requires the machine to lose power, not a forgotten manual step.

WHY PYTHON, NOT A MIX TASK OR SHELL SCRIPT
  This project's own dev hosts are Windows (docs/anti-patterns.md logs
  more than one Windows-quoting/line-ending hazard with `sed -i` and
  Git Bash path mangling). A `mix task` would need the *unmutated*
  project to compile before it could even run, which is backwards for a
  tool whose whole job is to run code that the mutation is expected to
  break. A raw shell one-liner (`sed -i 's/old/new/'`) cannot enforce
  "exactly one occurrence" portably and mis-encodes UTF-8/newlines on
  Windows. Stdlib-only Python has none of these problems and is already
  a proven, working choice here -- this is the second WF-03 run to reach
  for it for exactly this job (docs/agents/shared/HANDOFF_PROTOCOL.md
  also invokes `python` inline for timestamp handling).

USAGE
  python scripts/mutate.py <file> <old> <new> -- <test-command...>

  <file>          path to the target module (relative to repo root or
                  absolute)
  <old>           exact substring to replace -- MUST occur exactly once
                  in <file>, or the script refuses to mutate (exit 2)
  <new>           replacement substring (use '' for a deletion mutant)
  <test-command>  the command to run against the mutated file, e.g.
                  mix test test/mix/tasks/foo_test.exs
                  (everything after the literal `--` is passed to
                  subprocess as argv, unshelled -- no shell quoting
                  hazards; on Windows, pass the interpreter explicitly,
                  e.g. `-- mix test ...` runs `mix` via PATH lookup same
                  as any other subprocess call)

EXIT CODES
  0  mutant KILLED   -- the test command exited non-zero
  1  mutant SURVIVED -- the test command exited zero (a coverage gap)
  2  refused: <old> does not occur exactly once in <file> (0 or 2+
     matches) -- nothing was written, nothing to revert
  3  internal error (e.g. file not found, or the revert itself failed
     integrity verification) -- treat as a hard stop, not a mutant
     result

OUTPUT
  One machine-parseable summary line -- `MUTANT_KILLED` or
  `MUTANT_SURVIVED` -- printed after the test command's own stdout and
  stderr are relayed through unmodified.

GUARANTEES
  - Refuses to write unless <old> occurs in <file> EXACTLY ONCE. A
    typo'd or drifted mutant string is otherwise a silent no-op, and a
    "mutant" that never actually landed produces a false KILLED/SURVIVED
    reading -- the precise failure this script exists to make loud (see
    WF03-ISS0258-20260822 step-04b, section 7).
  - Preserves original bytes exactly: read/write UTF-8 with
    `newline=''` so no newline translation happens, and the revert is
    verified byte-identical to the pre-mutation content before this
    script exits.
  - ALWAYS reverts before exiting, including on Ctrl-C or an exception
    raised while the test command runs (try/finally around the
    subprocess call).
  - Never touches git (no worktree, branch, or index operation) -- pure
    file I/O against the one path given. For the "never mutate the
    working checkout at all" isolation technique WF-03 prefers for
    multi-mutant passes, run this from inside a throwaway `git worktree`
    rather than relying on the revert alone -- see
    docs/agents/workflows/WF-03_issue_resolving.md, "Isolation technique
    worth copying".

MUTANT TAXONOMY (matches this project's own WF-03 precedent -- see
ISS-0224's design doc use of "mutant"/"mutation" and
WF03-ISS0258-20260822's MS/MV-numbered mutants; this script does not
invent a new taxonomy, it is the applicator for the same one)
  A mutant here is always a SINGLE-OCCURRENCE SUBSTITUTION against one
  file's literal text -- one of:
    - operator swap        (`<` -> `<=`, `and` -> `or`)
    - comparison flip       (`n < 1` -> `n > 1`)
    - constant perturbation (`[:done, :in_progress, :blocked]` ->
                              `[:in_progress, :blocked]`)
    - deletion              (<new> = '', e.g. removing one alias-list
                              entry to prove a wiring line is covered)
  It is deliberately NOT a general AST-level mutation framework (no
  operator-coverage matrix, no automatic mutant generation) -- each
  mutant is hand-chosen by the calling agent to target a specific trap
  the fix under test exists to catch, per WF-03's "mutants must target
  the specific traps the fix exists to handle, not arbitrary breakage."

EXAMPLE (real demonstration -- see scripts/README.md)
  python scripts/mutate.py \\
    lib/mix/tasks/letflow.check_deferral_staleness.ex \\
    "@active_statuses [:done, :in_progress, :blocked]" \\
    "@active_statuses [:in_progress, :blocked]" \\
    -- mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
"""

import os
import shutil
import subprocess
import sys


def fail(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def main(argv):
    if "--" not in argv:
        fail(
            3,
            "usage: python scripts/mutate.py <file> <old> <new> -- <test-command...>",
        )

    sep = argv.index("--")
    head = argv[:sep]
    test_command = argv[sep + 1 :]

    if len(head) != 3:
        fail(
            3,
            "usage: python scripts/mutate.py <file> <old> <new> -- <test-command...>",
        )
    if not test_command:
        fail(3, "no <test-command> given after --")

    path, old, new = head

    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            original = f.read()
    except OSError as e:
        fail(3, f"could not read {path}: {e}")

    occurrences = original.count(old)
    if occurrences != 1:
        fail(
            2,
            f"refused: {old!r} occurs {occurrences} time(s) in {path} "
            "(must be exactly 1) -- nothing written",
        )

    mutated = original.replace(old, new, 1)

    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(mutated)
    print(f"MUTATE-APPLIED {path}")

    # Resolve the test command's own program via PATH ourselves rather than
    # relying on the platform loader to do it: on native Windows Python,
    # CreateProcess does not transparently resolve an extensionless PATH
    # entry (e.g. this repo's `mix`, a POSIX shell script with no
    # extension picked up by PATHEXT-aware shells) the way bash's `which`
    # does, and raises FileNotFoundError even though the same name runs
    # fine from a shell. shutil.which() finds that same extensionless
    # `mix` entry on PATH (verified on this repo's Windows dev host: it
    # resolves to the bare `mix` file, not `mix.bat`, so it is NOT doing
    # PATHEXT resolution itself here) -- what actually launches it is
    # `shell=True` below, which hands the resolved path to `cmd.exe`,
    # and `cmd.exe` is the one that does its own PATHEXT probe in that
    # directory and finds `mix.bat` there. Left untouched (and works
    # as-is, no shell needed) on POSIX.
    resolved = shutil.which(test_command[0])
    run_command = [resolved, *test_command[1:]] if resolved else test_command

    # A resolved .bat/.cmd (mix on Windows is `mix.bat`) is not itself a
    # PE executable -- CreateProcess can only launch it via cmd.exe, which
    # is what shell=True does. subprocess documents that on Windows,
    # shell=True + a list argument is safe and correctly quoted (unlike
    # POSIX, where shell=True + a list silently ignores everything past
    # the first element) -- so this is platform-conditional on purpose,
    # not a shortcut back to manual shell-string quoting.
    use_shell = os.name == "nt"

    try:
        result = subprocess.run(run_command, shell=use_shell)
        exit_code = result.returncode
    finally:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(original)
        with open(path, "r", encoding="utf-8", newline="") as f:
            reverted = f.read()
        if reverted != original:
            fail(
                3,
                f"REVERT INTEGRITY FAILURE on {path} -- restored content does not "
                "match the pre-mutation read. Do not trust this file; restore it "
                "from git manually (`git checkout -- <path>`) before doing anything "
                "else.",
            )
        print(f"MUTATE-REVERTED {path} (verified byte-identical)")

    if exit_code != 0:
        print("MUTANT_KILLED")
        sys.exit(0)
    else:
        print("MUTANT_SURVIVED")
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
