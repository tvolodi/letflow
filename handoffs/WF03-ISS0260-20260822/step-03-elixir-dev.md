# WF03-ISS0260-20260822 — Step 3 — ELIXIR-DEV

**Verdict:** PASS
**Design artefact implemented:** `lib/letflow/design/iss0260-ac1-timing-flake.md` (§3, all
subsections), passed by CODE-DESIGN-VALIDATOR at Step 2d.
**next_action:** Route to SECURITY-REVIEWER

## Files changed

- `test/letflow/engine_concurrency_test.exs`
  - Added `@ac1_timing_multiplier_default 30` and `@ac1_timing_multiplier_parallel 60`
    module attributes (design §3.1).
  - Added `ac1_timing_multiplier/0` private helper implementing the selection logic
    (design §3.2): `TEST_AC1_TIMING_MULTIPLIER` env override (validated against
    `^[1-9][0-9]*$`, `flunk/1` with a named-value message on rejection, mirroring
    `scripts/test_parallel.sh:124-127`'s `TEST_MAX_CONNECTIONS` validation style per
    design §3.3) takes precedence; otherwise `TEST_PARALLEL_GROUP` presence selects
    the parallel (60x) vs. default (30x) constant.
  - Replaced the bare `assert concurrent_micros < baseline_micros * 30` with
    `assert concurrent_micros < baseline_micros * multiplier, <message>` where the
    message interpolates the computed ratio, the multiplier actually used, and whether
    `TEST_PARALLEL_GROUP` was set (design §3.4).
  - No change to any correctness assertion, `baseline_micros` measurement method, or
    AC2/AC4/AC5 (design §3.5) — verified by re-reading the diff before commit.
- `lib/letflow/design/req-055-concurrent-instance-isolation.md`
  - §3.4 Case AC1's "No-cross-contention" bullet: added an "ISS-0260 update" paragraph
    noting the multiplier shipped as 30x (already stale relative to the doc's original
    "e.g. 3x" placeholder before this issue) and is now regime-dependent, pointing to
    the ISS-0260 design doc for the constants/derivation (design §5 first bullet).
  - §6 OQ2: added an "ISS-0260 update" paragraph recording the real-load measurements
    (34.0x, 29.42x) and the split into a load-aware pair, framed as tuning within OQ2's
    already-granted latitude, not a reopening of REQ-055 (design §5 second bullet).

## What was NOT touched (confirmed)

`lib/letflow/engine.ex`, `Letflow.Engine.Reconstruction`, `InstanceProjection`, and the
concurrency model — untouched, per design scope and the dispatch's explicit "do not
touch" list. No other test file changed.

## Verification (all commands run for real, output quoted)

### 1. `mix compile --warnings-as-errors`

```
$ mix compile --warnings-as-errors
(no output — clean)
```

### 2. `mix format --check-formatted`

```
$ mix format --check-formatted
(no output — clean)
```

### 3. Plain `mix test` (TEST_PARALLEL_GROUP unset) — 30x path

```
$ unset TEST_PARALLEL_GROUP; mix test test/letflow/engine_concurrency_test.exs
...
Finished in 23.3 seconds (0.00s async, 23.3s sync)
Result: 3 passed
```

All 3 tests in the file passed (AC1, AC2, AC4 — AC5 intentionally absent, see the
file's own moduledoc). AC1 passed using the unchanged 30x default multiplier.

### 4. `TEST_PARALLEL_GROUP` set — confirm the 60x branch is actually selected

Per the dispatch's instruction, added a temporary
`IO.puts("DEBUG-ISS0260-TEMP multiplier_selected=#{multiplier}")` immediately after
`multiplier = ac1_timing_multiplier()`, ran:

```
$ TEST_PARALLEL_GROUP=manualcheck mix test test/letflow/engine_concurrency_test.exs --no-color
...
DEBUG-ISS0260-TEMP multiplier_selected=60
...
Result: 3 passed
```

Confirmed the parallel-regime constant (60) is selected when `TEST_PARALLEL_GROUP` is
set, and the test still passes at that threshold. The debug line was then removed
(`git diff` / current file content confirms no `DEBUG-ISS0260-TEMP` string remains),
and `mix compile --warnings-as-errors`, `mix format --check-formatted`, and the plain
`mix test test/letflow/engine_concurrency_test.exs` run were all re-executed after
removal — same clean/passing results as steps 1-3 above (re-run output: `Result: 3
passed`, no compile/format output).

Full `scripts/test_parallel.sh`-wrapped run (16-way, real cross-partition contention)
was not additionally executed beyond the manual `TEST_PARALLEL_GROUP` check above — the
manual check already exercises the exact branch-selection logic under test (the
`TEST_PARALLEL_GROUP` presence check), and a full 16-way suite run is materially more
expensive for the same piece of evidence (confirming which multiplier is chosen); the
worst-case ratio question (whether 60x holds under real contention) is TEST-RUNNER's/
RELEASE-VALIDATOR's Step-4/5 territory per the design doc's own OQ-A, not something
this step re-litigates.

## Self-review checklist (per elixir-dev.md)

- State transition changed? No — test-infrastructure only, no `process_instance.ex` or
  state-machine change. README's ASCII diagram untouched, correctly.
- `process_instance.ex` touched? No.
- Migration added? No.
- `mix compile`/`mix format` run? Yes, both clean, quoted above.

## Tenant-data-path applicability call

This change touches only `test/letflow/engine_concurrency_test.exs` (a test file, not
an API route/migration/secrets/response-shaping path) and a prose-only design-doc
update. Per the dispatch's own instruction, I am not skipping the gate myself — routing
to SECURITY-REVIEWER first so that determination is made independently rather than
assumed by this step. If SECURITY-REVIEWER determines it is structurally inapplicable
(no tenant-data path touched), it should route directly to REVIEWER per the workflow.

## Issues / deviations

None. Implementation followed the design doc's §3.1-§3.5 and §5 exactly; no ambiguity
encountered requiring a judgment call outside the doc's spec.
