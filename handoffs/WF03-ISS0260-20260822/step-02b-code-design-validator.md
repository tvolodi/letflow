# WF03-ISS0260-20260822 — Step 2b — CODE-DESIGN-VALIDATOR

**Verdict:** FAIL
**Design artefact reviewed:** `lib/letflow/design/iss0260-ac1-timing-flake.md`
**next_action:** Route back to CODE-DESIGNER — one specific, scoped addition required
(§7 OQ-B), plus a factual correction to the text that currently justifies leaving it
unspecified. Everything else in the design independently re-derived as sound; do not
reopen §2/§3.1's chosen shape.

## What was independently re-checked (not taken on the designer's word)

1. **Detection power under both multipliers** — re-derived from the design's own
   numbers, not copied. 30x (default, unchanged) and 60x (parallel) both sit far below
   the ~100x (`@instance_count`) global-lock signature: a real regression would clear
   the 60x parallel ceiling by ~40 points (~1.7x overshoot), and the 30x default ceiling
   is untouched from today. Sound — confirms the design's §4 claim rather than assuming
   it.
2. **60x derivation** — checked against both real measurements (34.0x, 29.42x) recorded
   in the design and in ISSUE-FIXER's diagnosis. 60x = ~1.75x headroom over the worst
   observed 34.0x, comfortably clears both points, and stays well under the 100x alarm
   band. Only two data points exist, which the design itself flags as OQ-A rather than
   hiding — that is the right way to carry an admitted limitation forward (matches the
   `req-055` doc's own "expected tuning latitude" framing at §6 OQ2, checked directly).
   Not a blocker: OQ-A is correctly scoped as "retune the constant later if a third
   measurement warrants it," not "the load-aware shape might be wrong."
3. **Scope** — read `test/letflow/engine_concurrency_test.exs:265-306` directly. Only
   the AC1 timing assertion is implicated; `{:ok, %{instance_status: :completed}}` and
   the per-instance `InstanceProjection` corruption checks are untouched by the design
   as written. No `lib/letflow/engine.ex` / `Reconstruction` changes proposed. Confirmed
   in scope.
4. **Detection power preserved, not weakened** — the design does not delete or log-only
   the assertion (rejected option 3 in its own §2, correctly, per this run's explicit
   anti-pattern warning). Confirmed via §4's own per-regime margin statement, re-derived
   above.
5. **`req-055-concurrent-instance-isolation.md` update honesty** — read §3.4
   (lines 345-356) and §6 OQ2 (lines 492-500) directly. The design's required edit
   (§5) correctly identifies that the current doc text ("~1-3x", "judgment call, not a
   value taken from any existing precedent") is already stale against the shipped 30x
   and would become doubly stale once split into two regime-dependent constants. The
   specified edit instructs updating the text to state the new constants, cite the two
   ISS-0260 measurements, and frame this as tuning within OQ2's already-granted latitude
   — not a silent number change. Sound.

## The one failing check: §7 OQ-B (error shape left unspecified, on a factually wrong premise)

The design's §3.3 recommends trusting `TEST_AC1_TIMING_MULTIPLIER`'s raw value
unvalidated, "matching decision 0009's `TEST_MAX_CONNECTIONS`/`TEST_CONNECTION_HEADROOM`/
`TEST_MIN_POOL_SIZE` knob pattern... which do not validate either, per that decision's
shipped `config/test.exs` reads" (§3.3, repeated in §7 OQ-B). **This premise is false —
checked directly against the shipped code, not taken on the design's word:**

`scripts/test_parallel.sh:124-127` (decision 0009's actual implementation):
```sh
if ! printf '%s' "$max_conn" | grep -Eq '^[1-9][0-9]*$'; then
  echo "test_parallel: ERROR TEST_MAX_CONNECTIONS='$max_conn' is not a positive integer" >&2
  exit 1
fi
```
`TEST_MAX_CONNECTIONS` **is** explicitly validated — regex-checked for "positive
integer," with a clear, named error message and a non-zero exit — before it is ever
used in the budget arithmetic. Decision 0009's actual precedent is therefore "validate
the knob that feeds directly into a bound comparison, with a message that names which
variable failed and why," not "trust every knob unvalidated."

This matters because §7 explicitly defers this exact question to
CODE-DESIGN-VALIDATOR ("give a clear verdict, don't leave it dangling for ELIXIR-DEV to
improvise on" — this run's own dispatch), and the design's own recommended default
rests on a checkable claim that doesn't hold up. Per the design-validator checklist
("function signatures/interfaces fully specified including error shape," "no
TBD/deferral language"), an override's parse/validation behavior is exactly the kind of
error-shape detail that must be nailed down before ELIXIR-DEV implements, not left as
an open question resolved by an incorrect analogy.

### Verdict on OQ-B (mine, not deferred further)

**Validate.** `TEST_AC1_TIMING_MULTIPLIER`, when set, must be checked to be a positive
integer before use, mirroring decision 0009's actual `TEST_MAX_CONNECTIONS` pattern
(not the design's mistaken description of it):
- On a valid positive integer string: use it, unconditionally overriding both
  `@ac1_timing_multiplier_default` and `@ac1_timing_multiplier_parallel` (unchanged from
  the design's §3.3 selection order).
- On an unset env var: fall through to the existing `TEST_PARALLEL_GROUP`-gated
  selection (unchanged).
- On a set-but-invalid value (non-integer, zero, or negative): raise with a message
  naming the variable and the bad value (e.g.
  `raise "TEST_AC1_TIMING_MULTIPLIER=#{value} is not a positive integer"`), evaluated at
  the same module-attribute/compile-time point the design already specifies for reading
  this var (§3.1) — i.e. fail loudly and immediately, not silently coerce or crash later
  inside the `assert` with an opaque `ArithmeticError`/`ArgumentError` on a raw
  `String.to_integer` call. This is strictly better than decision 0009's own precedent
  (which validates via shell regex, not Elixir), not merely consistent with it — no
  reason to regress from a clear custom message to a generic one, since both cost the
  same amount of code (one guard).

## What CODE-DESIGNER must add before this passes

1. In §3.3: replace the "trust it unvalidated" recommendation and its false premise
   about decision 0009 with the validation behavior above (or forward-reference this
   handoff's resolution — either is acceptable, but the error shape must be stated in
   the design artefact itself, not only in this gate's handoff, since ELIXIR-DEV reads
   the design doc as its implementation contract).
2. Correct §3.3/§7's factual claim about decision 0009 not validating its knobs — it
   validates `TEST_MAX_CONNECTIONS` explicitly (`scripts/test_parallel.sh:124-127`).
3. No other change required. §2, §3.1, §3.2, §3.4, §3.5, §4, §5, §6, and OQ-A stand as
   written — do not regenerate the whole document, patch only §3.3/§7 OQ-B.

## Non-blocking notes carried forward (not failures)

- OQ-A (60x derived from two data points) is legitimately open per the design's own
  framing; TEST-RUNNER's Step 4 real 16-way run is the right place to add a third data
  point, and the design already states the correct response if that point trends toward
  60x (raise the constant under the same derivation method, not evidence the shape is
  wrong). No action required from CODE-DESIGNER on this one.
