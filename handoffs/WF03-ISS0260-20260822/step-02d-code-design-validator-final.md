# WF03-ISS0260-20260822 — Step 2d — CODE-DESIGN-VALIDATOR (final)

**Verdict:** PASS
**Design artefact reviewed:** `lib/letflow/design/iss0260-ac1-timing-flake.md` (as of
commit `25016bf`), specifically §3.3 and §7 OQ-B, re-checked against the real
`scripts/test_parallel.sh`.
**next_action:** Route to ELIXIR-DEV for implementation (WF-03 Step 3)

## What was independently re-verified against the real file (not taken on the doc's word)

Read `scripts/test_parallel.sh:110-134` directly:

```
119  if [ -z "${TEST_POOL_SIZE:-}" ]; then
120    max_conn="${TEST_MAX_CONNECTIONS:-100}"
121    headroom="${TEST_CONNECTION_HEADROOM:-10}"
122    min_pool="${TEST_MIN_POOL_SIZE:-2}"
123    (blank)
124    if ! printf '%s' "$max_conn" | grep -Eq '^[1-9][0-9]*$'; then
125      echo "test_parallel: ERROR TEST_MAX_CONNECTIONS='$max_conn' is not a positive integer" >&2
126      exit 1
127    fi
```

**Citation confirmed correct.** Lines 124-127 are exactly the `if`/`grep -Eq`/`echo`/
`exit 1`/`fi` block that regex-validates `TEST_MAX_CONNECTIONS` as a positive integer
(`^[1-9][0-9]*$`) and fails loudly with a named-value error message before the value is
used in the pool-size budget arithmetic (lines 129-133). This matches §3.3's
"Correction" paragraph's description of the block verbatim (pattern, message text,
exit-1 behavior).

**Both citations now agree and are both correct:**
- §3.3's "Correction" paragraph cites `scripts/test_parallel.sh:124-127` — correct,
  covers the full validation block including the closing `fi`.
- §7 OQ-B cites the same range, `scripts/test_parallel.sh:124-127` — correct, and now
  consistent with §3.3 (previously 120-126, a different and also-wrong range).

This resolves the sole blocking issue from the prior (Step 2c) FAIL: the citation
inaccuracy. No new gap introduced by this correction — it is a line-number fix only,
no prose or substance changed beyond the numbers.

## Requirement-by-requirement status (carried from Step 2c)

1. Correct the false claim (decision 0009's knobs are unvalidated) — DONE, confirmed
   PASS at Step 2c, unchanged since.
2. `TEST_AC1_TIMING_MULTIPLIER` validated as positive integer, same style, named-value
   error message — DONE, confirmed PASS at Step 2c, unchanged since.
3. OQ-B resolved, not open — DONE, confirmed PASS at Step 2c, unchanged since.
4. (Step 2c's sole remaining item) §3.3 and §7 OQ-B cite the correct, consistent line
   range for the validation block — DONE. Both now read `124-127`, verified against the
   live file above.

## Nothing else reopened

Confirmed by reading the current file end-to-end: §2, §3.1, §3.2, §3.4, §3.5, §4, §5,
§6, and OQ-A are byte-for-byte unchanged from the version already passed on every prior
point across Steps 2b/2c. Only §3.3's two citation numbers and §7 OQ-B's matching
citation changed in commit `25016bf`. No implementation code is present anywhere in the
doc (signatures/constants/validation rules only, no `.ex` bodies). No TBD/deferral
language present.

## Overall verdict

All three original CODE-DESIGN-VALIDATOR requirements (false-claim correction,
validation spec for the new env knob, OQ-B resolution) and the one follow-up citation
fix are now satisfied and independently verified against the real
`scripts/test_parallel.sh` source, not the design doc's own word. **PASS — design is
ready for ELIXIR-DEV.**
