# WF03-ISS0260-20260822 — Step 3c — REVIEWER

**Verdict:** PASS
**next_action:** Route to TEST-DESIGNER (WF-03 Step 4)

## 1. Implementation vs. approved design

Compared `git show 3c08067` directly against
`lib/letflow/design/iss0260-ac1-timing-flake.md` §3, not against ELIXIR-DEV's summary.

- `@ac1_timing_multiplier_default 30` / `@ac1_timing_multiplier_parallel 60` — present,
  matches §3.1 exactly (values and rationale comment both correct; comment cites the
  design doc path).
- `ac1_timing_multiplier/0` selection order — checks `TEST_AC1_TIMING_MULTIPLIER` first
  (unconditional override, §3.3), falls back to `TEST_PARALLEL_GROUP` presence-check
  (§3.2, `nil ->`/`_group ->` shape mirroring `config/test.exs`'s own case exactly).
  Matches.
- `TEST_AC1_TIMING_MULTIPLIER` validation — `Regex.match?(~r/^[1-9][0-9]*$/, value)`,
  same pattern §3.3 specifies (mirrors `test_parallel.sh`'s
  `grep -Eq '^[1-9][0-9]*$'`). On mismatch: `flunk("TEST_AC1_TIMING_MULTIPLIER='#{value}'
  is not a positive integer")` — matches the design's named-value message shape
  verbatim, substituting only the variable name as instructed.
- Assertion message (§3.4) — interpolates the ratio (rounded), the multiplier used, and
  `TEST_PARALLEL_GROUP` set/unset, plus both raw `baseline_micros`/`concurrent_micros`.
  Matches "state the ratio and regime directly" requirement.
- §3.5 (what does not change) — confirmed by diff: no touch to
  `lib/letflow/engine.ex`, `InstanceProjection`, `Letflow.Engine.Reconstruction`, the
  correctness assertions, or `baseline_micros`'s measurement method.

Implementation is a faithful, line-for-line realization of the approved design. No
deviation found.

## 2. Idiomatic OTP/Elixir usage

- `flunk/1` for a malformed env var in ExUnit test setup is the right mechanism here,
  not `raise` or `System.halt/1`. This runs inside a test body (module-attribute-time
  evaluation is not involved — `ac1_timing_multiplier/0` is a function called at
  assertion time, not at compile time, despite the two `@ac1_timing_multiplier_*`
  constants being module attributes). `flunk/1` produces a normal ExUnit test failure
  with the message as the failure reason, which is exactly the desired behavior: fail
  *this test*, loudly, with a clear diagnostic — not crash the whole `mix test` BEAM
  process (`System.halt/1`) or raise an unrelated-looking exception whose message
  ExUnit still surfaces the same way `flunk/1`'s would, but with less idiomatic intent
  signaling. `flunk/1` is the ExUnit-idiomatic choice for "this precondition is invalid,
  fail the test now."
- `ac1_timing_multiplier/0` reads cleanly: two-level `case`/`case` nesting, no deeply
  nested control flow, each branch does exactly one thing (delegate, or select, or
  validate-and-convert-or-flunk). No crutch pattern — this is not a `GenServer`/`case`
  masquerading as a state machine (not applicable here at all; this is a pure test
  helper function, not OTP process code).
- No supervision concern applies — this change touches no process, no
  `Letflow.InstanceSupervisor`, no `gen_statem`. Item 2 of the REVIEWER charter (per-
  instance supervised isolation) is not engaged by a test-file timing-assertion change.
- No new type-safety gap: the two multipliers are plain integers already representable
  correctly as module attributes; the env-var validation converts an external string to
  an integer at the one point it's used, with the invalid case rejected explicitly
  rather than silently coerced (e.g. no `String.to_integer/1` on unvalidated input,
  which would raise `ArgumentError` with a far less useful message). Nothing here calls
  for a struct/`@type`/`Ecto.Enum` change — this is test-only scalar configuration, nothing
  representable as an invalid *domain* state.

## 3. Scope discipline

`git diff --stat main...HEAD` for the whole branch:

```
lib/letflow/design/iss0260-ac1-timing-flake.md          | 245 (new)
lib/letflow/design/req-055-concurrent-instance-isolation.md | 30 +-
test/letflow/engine_concurrency_test.exs                 | 45 +-
handoffs/WF03-ISS0260-20260822/*.md                      (handoff records)
```

No `lib/letflow/engine.ex`, no `Letflow.Engine.Reconstruction`, no
`Letflow.InstanceSupervisor`, no migration, no other test file. Matches the design
doc's own declared scope header exactly ("test-infrastructure only ... and the
corresponding rationale text in `req-055-concurrent-instance-isolation.md` §3.4/§6
OQ2"). No scope creep — no new abstraction, behaviour, or macro introduced; the two
module attributes and one private helper are the minimum machinery §3.1-§3.3 calls
for, nothing ahead of it.

## 4. Decision-record consistency

Checked the req-055 doc edit against what actually shipped, not just what the design
doc proposed:

- §3.4 Case AC1 bullet: replaces "some multiple (e.g. 3x)" / "~1-3x" placeholder text
  with an honest statement that 30x is what actually shipped (already stale before
  ISS-0260, per the design doc's own §5 framing) and that the threshold is now
  regime-dependent, pointing to the ISS-0260 design doc. This does not silently change
  a number — it explicitly narrates that the placeholder was already stale and states
  what replaced it and why. Honest.
- §6 OQ2: appends a paragraph recording both real measurements (34.0x, 29.42x) and
  framing the split as tuning within OQ2's already-granted latitude, not a reopening of
  REQ-055's design. Consistent with OQ2's original text (verified by reading the
  surrounding unmodified §6 context in the diff) — OQ2 already said future numeric
  retuning was in scope without a new design-doc cycle, so this update is exactly what
  it anticipated, not a reinterpretation.
- Decision 0009 (`TEST_MAX_CONNECTIONS` precedent): independently re-verified against
  the actual shipped `scripts/test_parallel.sh` source (not re-trusting the design
  doc's or CODE-DESIGN-VALIDATOR's prior claim):
  ```
  scripts/test_parallel.sh:124  if ! printf '%s' "$max_conn" | grep -Eq '^[1-9][0-9]*$'; then
  scripts/test_parallel.sh:125    echo "test_parallel: ERROR TEST_MAX_CONNECTIONS='$max_conn' is not a positive integer" >&2
  scripts/test_parallel.sh:126    exit 1
  ```
  Confirms the design doc's §3.3 "Correction" section is accurate: decision 0009's
  actual precedent is "validate an env knob feeding a bound/arithmetic comparison, with
  a named-value error message" — exactly what `ac1_timing_multiplier/0` does. The
  SHIPPED code (`test/letflow/engine_concurrency_test.exs`'s `flunk` message text)
  matches this precedent's message shape, substituting only the variable name, as
  required.

No silent divergence from any decision record found.

## 5. Independent verification (all commands re-run by REVIEWER, not inherited)

Copied `.env` from the parent checkout into this worktree root; confirmed
`LETFLOW_DB_PORT=5472`.

```
$ mix compile --warnings-as-errors
(no output — clean)

$ mix format --check-formatted
(no output — clean)

$ mix test test/letflow/engine_concurrency_test.exs
...
Finished in 22.2 seconds (0.00s async, 22.2s sync)
Result: 3 passed
```

All three independently re-confirmed clean/passing, matching ELIXIR-DEV's claimed
results.

## Verdict

PASS. Implementation is a faithful realization of the approved design, uses idiomatic
ExUnit/Elixir mechanisms (`flunk/1` for test-setup precondition failure), stays fully
within the declared scope (test file + the one design-doc's own rationale-text update
it names), and the req-055 doc edit is an honest, non-silent update consistent with
decision 0009's actual (re-verified) precedent. No OTP/supervision concern applies —
this change touches no process code. No BLOCKER or MAJOR issues found. No new
type-safety gap warrants filing under `docs/issues/`.

## Next action

Route to TEST-DESIGNER (WF-03 Step 4).
