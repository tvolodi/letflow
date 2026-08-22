# WF03-ISS0260-20260822 — Step 2c — CODE-DESIGN-VALIDATOR (re-check)

**Verdict:** FAIL
**Design artefact reviewed:** `lib/letflow/design/iss0260-ac1-timing-flake.md` (as of
commit `7b72bf0`), specifically §3.3 and §7 OQ-B, re-checked against the real
`scripts/test_parallel.sh`.
**next_action:** Route back to CODE-DESIGNER — one small, scoped correction: fix §3.3's
line-number citation. Everything else re-confirmed sound; do not reopen anything else.

## What was independently re-verified against the real file (not taken on the doc's word)

Read `scripts/test_parallel.sh:105-135` directly:

```
119  if [ -z "${TEST_POOL_SIZE:-}" ]; then
120  max_conn="${TEST_MAX_CONNECTIONS:-100}"
121  headroom="${TEST_CONNECTION_HEADROOM:-10}"
122  min_pool="${TEST_MIN_POOL_SIZE:-2}"
123  (blank)
124  if ! printf '%s' "$max_conn" | grep -Eq '^[1-9][0-9]*$'; then
125    echo "test_parallel: ERROR TEST_MAX_CONNECTIONS='$max_conn' is not a positive integer" >&2
126    exit 1
127  fi
```

**Substance confirmed correct:** `TEST_MAX_CONNECTIONS` genuinely is regex-validated as
a positive integer with a named-value error message before use, exactly as the
"Correction" paragraph in §3.3 now states. The prior FAIL's false-claim issue (design
previously asserted decision 0009's knobs are unvalidated) is substantively fixed.

**But the citation itself is wrong and internally inconsistent:**
- §3.3's "Correction" paragraph cites `scripts/test_parallel.sh:120-123` for "explicitly
  regex-validates ... and exits 1 with a named error message." Lines 120-123 are only
  the three variable assignments (`max_conn`, `headroom`, `min_pool`) plus a blank line
  — **none** of the regex check, echo, or exit statements the sentence describes are in
  that range. The actual `if ! printf ... | grep -Eq ...`/`echo .../exit 1` block is at
  lines 124-127.
- §7 OQ-B cites the same fact as `scripts/test_parallel.sh:120-126` — a different,
  closer-but-still-imprecise range (it does include lines 124-126, unlike §3.3's
  120-123, but still omits the closing `fi` at 127 and includes irrelevant assignment
  lines).

So the two sections of the same doc give two different, both-imprecise citations for
one fact, and §3.3's own citation — the one carrying the "Correction" framing that is
supposed to demonstrate the claim was re-checked against real source — does not
actually cover the validation logic it's citing as evidence. This is exactly the kind
of unverified citation the prior FAIL was about; fixing the substance without fixing
the citation leaves the doc's "checked against the actual shipped source" claim
half-true.

## Requirement-by-requirement status (from the prior FAIL)

1. **Correct the false claim (decision 0009's knobs are unvalidated)** — DONE. Substance
   is now accurate: `TEST_MAX_CONNECTIONS` is validated, confirmed independently.
2. **Add a spec requiring `TEST_AC1_TIMING_MULTIPLIER` to be validated as a positive
   integer, same style, named-value error message** — DONE. §3.3 now specifies
   `^[1-9][0-9]*$`, fail-loudly-at-test-setup, message shape
   `"TEST_AC1_TIMING_MULTIPLIER='<value>' is not a positive integer"` mirroring
   `test_parallel.sh`'s own message. Matches my prior handoff's required error shape.
3. **Resolve OQ-B as answered, not open** — DONE. §7 states "OQ-B — resolved, not
   open" with the validate-it verdict, matching (1)/(2).

Two of three requirements are cleanly satisfied. The blocking issue is narrower than
the original FAIL: not a false factual premise, but an inaccurate/inconsistent line
citation supporting an otherwise-correct claim.

## Nothing else reopened

§2, §3.1, §3.2, §3.4, §3.5, §4, §5, §6, and OQ-A are unchanged from the version
previously passed on every other point — confirmed by reading the current file; no
other section was touched in this revision beyond §3.3's added "Correction" paragraph/
validation spec and §7 OQ-B's resolution text.

## What CODE-DESIGNER must fix before this passes

In §3.3, replace the citation `scripts/test_parallel.sh:120-123` with a range that
actually contains the `if`/`grep`/`echo`/`exit`/`fi` block being cited — `124-127` (or
`120-127` if the intent is to also show the variable being validated in context). Align
§7 OQ-B's citation to the same corrected range for consistency. No other change
required — do not regenerate the document.
