# WF-03 Step 3c — REVIEWER

Run: `WF03-ISS0261-20260822`
Agent: `REVIEWER`
Under review: `scripts/mutate.py`, `scripts/README.md`,
`docs/status/requirement_status.v2.yaml` (new entry),
`docs/status/requirement_status.index.yaml` (`entries:` bump)

---

## VERDICT: PASS

SECURITY-REVIEWER confirmed out of scope, stated explicitly (not skipped
silently): Mix-external Python tooling under `scripts/`, no tenant-data path,
no HTTP surface, no migration, no secret.

### Verified by direct execution (not just reading)
- Single occurrence + failing test command -> MUTATE-APPLIED -> MUTATE-REVERTED
  (byte-identical) -> MUTANT_KILLED, exit 0.
- Zero occurrences -> refused, nothing written, exit 2.
- Single occurrence + passing test command -> MUTANT_SURVIVED, exit 1.
- `shutil.which('mix')` + `shell=(os.name=="nt")` end-to-end on this Windows
  host: works (`mix --version` via the resolved binary, exit 0).

### Findings
- MINOR-1: the Windows-resolution comment misattributed `.bat` resolution to
  `shutil.which()` itself; the real mechanism is `cmd.exe`'s own PATHEXT
  probe under `shell=True`. Behavior was already correct -- **fixed the
  comment** in this same run (`scripts/mutate.py`, the block above
  `resolved = shutil.which(...)`), re-verified the MS3 demonstration still
  reproduces 43/57 passed / 14 red / MUTANT_KILLED / clean revert after the
  comment-only edit.
- MINOR-2: `docs/status/requirement_status.v2.yaml` has crossed its
  1,200-line roll threshold (pre-existing on `main` before this run's own
  append -- 1,235 lines before, now 1,262). Flagged for ORCH/DOC-UPDATER to
  roll to v3; out of scope for ISS-0261 to fix (systemic, affects every
  concurrent run appending to this file, not introduced or worsened
  specifically by this change beyond one ordinary append).

Placement (`scripts/`, consistent with `test_parallel.sh`/`timed_test.sh`),
scope (single-occurrence substitution helper, explicitly not a general
mutation framework), and documentation sufficiency (full header docstring +
`scripts/README.md` worked example) all confirmed adequate.

No MAJOR findings. No rework required.
