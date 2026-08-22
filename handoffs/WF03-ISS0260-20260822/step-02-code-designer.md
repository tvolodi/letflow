# WF03-ISS0260-20260822 — Step 2 — CODE-DESIGNER

**Verdict:** PASS (revised — see "Revision after CODE-DESIGN-VALIDATOR FAIL" below)
**Design artefact:** `lib/letflow/design/iss0260-ac1-timing-flake.md`
**next_action:** Route to CODE-DESIGN-VALIDATOR for a re-check of the §3.3/§7 OQ-B
delta only (validator already confirmed the rest of the design sound independently).

## Revision 2 — citation fix after second CODE-DESIGN-VALIDATOR FAIL

CODE-DESIGN-VALIDATOR FAILed the original design on one point only: §3.3/§7 OQ-B claimed
decision 0009's env knobs (`TEST_MAX_CONNECTIONS` etc.) "do not validate either," and
used that as the rationale for leaving `TEST_AC1_TIMING_MULTIPLIER` unvalidated. That
premise was checked directly against `scripts/test_parallel.sh:120-126` and confirmed
**wrong** — the script explicitly regex-validates `TEST_MAX_CONNECTIONS` as a positive
integer (`^[1-9][0-9]*$`) and exits 1 with a named-value error message before use.
Decision 0009's actual precedent is therefore "validate a knob that feeds a bound
comparison, with a clear message" — the opposite of what the design originally cited.

Fixed, scoped to §3.3 and §7 OQ-B only:
1. §3.3 now states the corrected decision-0009 precedent and specifies
   `TEST_AC1_TIMING_MULTIPLIER` MUST be validated as a positive integer
   (`^[1-9][0-9]*$`) at the multiplier-selection point, rejecting with a named-value
   error message mirroring `test_parallel.sh`'s own `TEST_MAX_CONNECTIONS` message
   shape.
2. §7 OQ-B is now marked resolved (not open), states the correction, and asks
   TEST-DESIGNER for an explicit invalid-value test case.

Nothing else in the design changed — §1, §2, §3.1/§3.2/§3.4/§3.5, §4, §5, §6, and OQ-A
are untouched, matching what CODE-DESIGN-VALIDATOR already confirmed sound.

## Summary (original, still accurate except the §3.3/OQ-B correction above)

Designed the fix for ISS-0260's AC1 timing-assertion flake
(`test/letflow/engine_concurrency_test.exs:306`,
`assert concurrent_micros < baseline_micros * 30`). Chose option (2) from ORCH's three
named candidates — make the assertion load-aware — over (1) loosen uniformly and
(3) convert to non-blocking benchmark.

**Why (2), against the actual measured numbers:** two independent real-load
measurements under `scripts/test_parallel.sh`'s genuine 16-way mode gave ratios of
≈34.0x (failed) and ≈29.42x (passed) — both far below the ~100x a real global-lock
regression would produce, showing the ratio is a function of load *regime*, not a fixed
property of the code. No evidence exists that plain `mix test` needs any loosening at
all. A single uniform constant loose enough to clear 34x would therefore be needlessly
loose in the regime that doesn't need it — the "unfounded constant" anti-pattern ORCH's
dispatch flagged for option (1). Option (3) was rejected outright per ORCH's own
constraint: this repo has no CI, so a log-only ratio nobody reads is equivalent to
deleting the check.

**The fix (design §3):** split into `@ac1_timing_multiplier_default = 30` (unchanged,
applies when `TEST_PARALLEL_GROUP` is unset) and `@ac1_timing_multiplier_parallel = 60`
(applies when `TEST_PARALLEL_GROUP` is set — the exact existing signal
`scripts/test_parallel.sh` already exports and `config/test.exs` already reads for
ISS-0217, so no new mechanism). 60 is derived, not guessed: ~1.75x headroom above the
worst observed 34.0x, while still only 60% of the ~100x global-lock signature. Adds one
override escape hatch, `TEST_AC1_TIMING_MULTIPLIER`, matching decision 0009's
`TEST_MAX_CONNECTIONS`/`TEST_CONNECTION_HEADROOM`/`TEST_MIN_POOL_SIZE` knob pattern for
this exact class of `mix test` vs. `scripts/test_parallel.sh` behavior split.

**Detection-power preserved (design §4):** a genuine regression at ~100x clears both
ceilings decisively (30x default, 60x parallel) — same margin as today in the default
regime, ~1.7x overshoot margin in the parallel regime. No regime this fix introduces
comes close to the ~100x signature.

**req-055 design doc update required (design §5):** §3.4 Case AC1's stale "~1-3x"
language and §6 OQ2's multiplier note both need updating to describe the new
regime-dependent constants and cite ISS-0260's measurements — recorded as a required
edit for ELIXIR-DEV to apply alongside the test-file change, not silently left stale.

**Scope respected:** test-infrastructure only. Did not touch `lib/letflow/engine.ex`,
`Letflow.Engine.Reconstruction`, or the concurrency model. No implementation code
written — signatures/constants/values only, in prose form.

## Acceptance criteria coverage

| criterion (from ORCH's dispatch) | where |
|---|---|
| pick one of the three candidates deliberately, justified against measured data | design §2 |
| loosening must be justified against precedent/measured data, not arbitrary | design §3.1 |
| must not simply delete/drastically weaken detection power | design §4 |
| must state explicitly how detection of a genuine ~100x regression is preserved | design §4 |
| keep req-055 doc's own reasoning honest if touched | design §5 |
| small, scoped, test-infrastructure only — no engine.ex/concurrency-model changes | design "Scope"/"Explicitly out of scope" header, §3.5 |

## Open questions carried to the Step-2b gate

OQ-A: the parallel multiplier (60x) is derived from exactly two data points; a third
measurement from TEST-RUNNER's regression-test run may warrant raising it further under
the same derivation method — not evidence the load-aware shape is wrong. OQ-B: whether
`TEST_AC1_TIMING_MULTIPLIER` should validate its input or trust it as-is (following
decision 0009's own precedent of trusting its knobs unvalidated).

Nothing was left unresolved for ELIXIR-DEV/TEST-DESIGNER to infer.
