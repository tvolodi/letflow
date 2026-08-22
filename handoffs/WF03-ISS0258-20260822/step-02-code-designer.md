# WF03-ISS0258-20260822 — Step 2 — CODE-DESIGNER

**Verdict:** PASS
**Design artefact:** `lib/letflow/design/iss0258-deferral-staleness-detection.md`
**next_action:** Route to CODE-DESIGN-VALIDATOR (WF-03 Step 2b).

## Acceptance criteria coverage

| criterion | where |
|---|---|
| surfaces a DEFERRED requirement whose stage became active, distinct from one legitimately pending an inactive stage | design §3.3 (ruling), §3.4 (applied to the live corpus), §5 rule S1, §6.2 `classify_deferral/3` returning `:stale` vs `:legitimate` |
| wired into an actual gate a human/CI will see | §D5 — slot 3 of the `letflow.check` alias; `mix.exs` is in §6.4's touched-files table |
| states explicitly WHY separate from `letflow.check_requirements_registration` | §D3 — three inherited reasons verified against the shipped source, plus two of my own |

## Rulings on the seven points

**(1) What counts as stale.** A stage is `:active` iff some requirement in it —
**excluding the entry under test** — has status in `{:done, :in_progress, :blocked}`.
`:pending` and `:cancelled` confer nothing; `:unknown` confers nothing and separately
hard-fails (S4).
- `cancelled` NOT active, and this is measured rather than asserted: S8 holds 1 cancelled
  + 10 pending, so counting it would make S8 active and flag **all 21 historical
  deferrals** — a rule wrong about 21 of 21 known-good cases.
- `blocked` **IS** active — **this overrides the Step-1 recommendation.** Reasons: the
  property is "has the stage been engaged with", and `blocked` is only reachable by
  someone starting work and recording an impediment; and the error costs are asymmetric
  (a missed stale deferral is the silent failure this issue exists to remove; a false
  positive is loud, named, and closable in one line). Measured cost today: zero — no
  requirement anywhere is `blocked`. Flagged as OQ-1 for REVIEWER to confirm or reverse;
  reversal is one token.
- Applied: S0–S4 active, S5/S6/S7 inactive (empty stage, by rule not exception),
  S8/S9 inactive. Retroactively classifies all 21 historical deferrals legitimate.
- Added a case the brief did not name: **self-exclusion** (§3.5), which removes the
  deferred-and-`done` entry that would otherwise activate its own stage and flag itself.
- A deferred entry with no `stage:` is `:undecidable` and violates S2 — not given the
  benefit of the doubt.

**(2) The false-positive class.** Accepted the recommended direction with a tightened
grammar: an anchored `blocked-by: REQ-NNN` scope prefix parsed out of the existing
rationale (no schema change to `docs/requirements.yaml`). Four load-bearing properties:
anchored at the rationale's start (unanchored is ISS-0231's M8 absorption bug in new
clothes); the named id must exist; the blocker's status is checked so **the hatch itself
expires** when the blocker is `done`/`cancelled`; free text still required so R3's spirit
survives. Self-reference rejected. Explicitly rejected and recorded: free-text exemption
(that is just R3 again), a date-based `expires:` hatch (a date is a promise, not a fact,
and it goes red for a reason unrelated to the world), and any id/wildcard exception list.

**(3) Separate detector vs. extension.** Verified independently, **upheld**. I checked
all three inherited reasons against the shipped source (its rules really are per-entry
plus two trivial file-level aggregates; its moduledoc really does contract that the
deferred count never affects the exit code, at any value) and added two of my own:
different *inputs* (`impl_order` lines vs. `status` lines) means a merged exit code would
cover two independent invariants and a red run would be ambiguous; and merging couples
the two mutant sets, since every staleness fixture would also have to satisfy R1–R6 —
which matters more than usual because §7 is the only place this fix has any regression
value at all. Honest cost of separation named: two report blocks and two task
invocations, bounded by the reuse ruling below.

**(4) Reuse vs. re-parse.** **Reuse.** Consume `CheckRequirementsRegistration.scan/1`;
do not write a second parser, which would drift into its own form-blindness — the
original ISS-0231 root cause recurring by duplication. The one bounded, explicitly named
addition: the `entry()` map gains `status: String.t() | nil`, extracted by a `@status_re`
that copies the existing `@stage_re`'s shape. It stores the **raw token, not a normalised
atom**, so all semantic interpretation stays in the new module and the old one remains a
dumb parser. It touches none of `:deferred`, `@marker_form_re`, R1–R6, `render/1`'s
"never gates" line, or the exit contract. ELIXIR-DEV must also confirm no existing test
pattern-matches that entry map exhaustively.

**(5) Placement.** Slot 3 of the `letflow.check` alias, immediately after
`letflow.check_requirements_registration`. Re-verified myself that **no CI configuration
of any kind exists** (`.github` absent, no `.gitlab-ci.yml`, no `.circleci`), so the alias
is not the primary gate surface but the only one; `mix letflow.lint_handoffs` is the local
counter-example of a good check wired into nothing. After registration so a *shape* break
surfaces as R2/R6 first; before `compile` because both are file-only doc checks. Decision
record 0005 legislates slot 1 only, so nothing on record is re-decided. Design is
indifferent to the exact index (OQ-4), firm about being in the alias.

**(6) Impact on today's `main`.** Re-measured in this worktree, not inherited:
`mix letflow.check_requirements_registration` prints `115 entries = 115 registered +
0 deferred + 0 neither + 0 unclassified` and `DEFERRED ...: none`; `grep -c 'impl_order:
UNREGISTERED' docs/requirements.yaml` returns **0**. The deferred set is genuinely empty,
so the gate is **vacuously green** and ships with **no grandfather clause and no exception
list of any kind** — ISS-0231's stance, adopted deliberately (I5/I6). Any future red is a
new fact.

**(7) Testability.** Public pure core taking **content, not a path** (`audit/1`), plus
`stage_activity/1`, `classify_deferral/3`, `parse_scope/1`, `normalise_status/1`, and
`render/1` all public so mutants have single targets. §7.2 states in requirement form that
the live corpus has **zero signal for S1/S2/S3** and that no mutant may cite a live-corpus
test as its only detector except the four rows where the corpus genuinely discriminates.
**13 named mutant traps** (MS1–MS13) with per-trap detectors, two marked mandatory:
**MS3** (drop `:done` from the active set ⇒ nothing is ever active ⇒ ISS-0258 reproduced
inside its own fix — the analogue of ISS-0231's M1) and **MS9** (accept `blocked-by:`
regardless of the blocker's status ⇒ the hatch never expires). ~30 fixture specs plus
four live-corpus specs are enumerated for TEST-DESIGNER.

## Something I found by spot-check that the diagnosis did not carry

**8 of the 115 `status:` lines carry a trailing comment**, e.g.
`status: cancelled  # MVP-1 milestone dropped, see REQ-101's note`. A rest-of-line status
extractor therefore yields a value matching no declared status, so S4 would fire on 8 real
entries and **the gate would be red on day one for a non-reason** — exactly the
credibility failure ISS-0231's D3 argues against. The extractor must take the first
whitespace-delimited token, mirroring the existing `@stage_re`. Recorded as design §6.3
and as mutant MS4, with fixture F-STATUS-TRAILING-COMMENT copied verbatim from the real
file. Also re-verified that all 115 `status:` lines sit at exactly 4 spaces and none
deeper, so the existing ≥4-space attribution rule covers them (MS5).

## Deliberately out of scope

- **Stale-by-time.** A deferral pending an inactive S8 stays legitimate for as long as S8
  stays unstarted, possibly months. That is a true statement about the world; the residual
  idle-pipeline risk is *stage-level*, not deferral-level, and belongs to a different
  detector. Recorded as OQ-6 for ORCH to `register_task` — the same shape in which
  ISS-0231's follow-up recorded this very issue, rather than dropped.
- **Registering anything.** No `impl_order` is added, guessed, or altered; no call to
  `letflow-queue`; `docs/requirements.yaml`'s data is untouched (only its line-8 status
  legend, per OQ-3).
- **Wiring `mix letflow.lint_handoffs`** into a gate — still unwired, still ISS-0231's
  open follow-up, not this run's.

## Open questions carried to the Step-2b gate

OQ-1 `blocked` counts as active (the one ruling against Step 1 — REVIEWER to confirm or
reverse); OQ-2 S4 applies to all 115 entries, not only deferral-adjacent ones; **OQ-3 a
real inconsistency I found — `docs/requirements.yaml` line 8 declares `pending |
in_progress | done | blocked` but `cancelled` is used 8 times and is undeclared**, ruled
in scope as a one-word legend fix; OQ-4 alias slot index; OQ-5 T-LIVE-ACTIVITY pins the
active set and will need updating when S5–S7 expand; OQ-6 stale-by-time, out of scope.

Nothing was left unresolved for ELIXIR-DEV to infer.
