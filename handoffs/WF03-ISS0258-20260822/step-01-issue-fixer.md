# WF03-ISS0258-20260822 — Step 0.5 + Step 1 — ISSUE-FIXER

**Verdict:** PASS
**next_action:** Route to CODE-DESIGNER for fix design.

## Step 0.5 — registry lookup

No prior *resolved* entry with matching symptoms. Searched `docs/issues/*.yaml` for
`expir|staleness|green forever|idle pipeline`; the hits reduce to one lineage —
`ISS-0221` (WF-01 never registered requirements) and `ISS-0231` (ISS-0221 closed on a
false all-clear; built the registration detector). `ISS-0230`, `ISS-0216`, `ISS-0207`,
`ISS-0208` were read and are unrelated (tenant provisioning, pagination cursor).

**This is NOT a recurrence.** ISS-0258 is the residual gap ISS-0231's own
`follow_ups:` block records verbatim ("The `:deferred` bucket is green forever, with no
expiry ... it is a different detector"). ISS-0231's fix held — it is green on `main`
today, measured below. Severity stays as filed; no escalation warranted.

## Step 1 — diagnosis (all claims measured, not inferred)

### The defect

`lib/mix/tasks/letflow.check_requirements_registration.ex` classifies every requirement
into `:registered | :deferred | :neither | :unclassified`. Rule **R3** is the only rule
touching `:deferred`, and it fires only when the rationale is `nil` or `""`:

    defp entry_violations(%{state: :deferred, rationale: r} = e) when r in [nil, ""] do

and the roster renderer is explicit that the bucket never gates:

    "DEFERRED (visible debt -- always reported, never gates)"

So *any* non-empty rationale string satisfies R3 forever. There is no time dimension, no
re-evaluation against the world, and no field anywhere that could expire. A requirement
deferred with a once-true reason stays green after that reason stops being true. That is
the ISS-0221 failure mode — a validated-looking requirement `get_next_task` never
returns, whose only symptom is an idle pipeline — displaced one layer up: `UNREGISTERED`
is now watched, and `DEFERRED` is the state nothing watches.

### Root cause, precisely

Not a bug in the detector's logic. The detector is correct for the failure class it was
scoped to. The root cause is a **missing invariant**: the project has a written rule for
*whether a deferral is documented* (TASK_QUEUE.md: marker + non-empty rationale
mandatory) and **no rule at all for whether a deferral is still justified**. R3 checks
the presence of a reason; nothing checks the reason's continued truth. A rationale is
free text and therefore unfalsifiable by construction — the same unfalsifiability that
made ISS-0221's all-clear survive a day.

### Measured live state — the deferred set is genuinely EMPTY

    $ mix letflow.check_requirements_registration
    ========================================================================
    mix letflow.check_requirements_registration -- docs/requirements.yaml
    ========================================================================
    DEFERRED (visible debt -- always reported, never gates): none
    ------------------------------------------------------------------------
    115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified
    ========================================================================

    $ grep -c 'UNREGISTERED' docs/requirements.yaml
    1

The single remaining `UNREGISTERED` occurrence is line 5606, inside the S8 prose block
note, at 2-space indent — excluded from attribution by the detector's `@attributed_re`
(`^ {4,}\S`) rule. **There are zero deferred entries on `main` right now.**

Consequence for design: a staleness gate is **vacuously green on today's `main`**, so it
can be wired in as a hard gate with **no grandfather clause and no exception list**.
Consequence for testing: as with ISS-0231's M1 mutant, the live corpus provides *zero*
regression signal — all discriminating power must come from hermetic fixture strings.

### What a real deferral rationale looked like (grounding, not hypothesis)

All 21 pre-PR#495 deferrals carried one identical rationale:

    $ git show 75f553d:docs/requirements.yaml | grep -n '# impl_order: UNREGISTERED'
    5567:    # impl_order: UNREGISTERED -- see the S8 note above
    ... (21 lines, all identical text)

Every real deferral this project has ever had was **stage-scoped** — a pointer to a
stage-level block note, deferring the whole S8/S9 batch pending the stage. That is
direct evidence the issue's proposed stage-activity signal matches the actual corpus.

### THE HARD PART — "active stage" is NOT a readable field

Verified against the `stages:` block. A stage entry carries exactly:

    - id: S8
      name: frontend-integration-and-cutover
      description: >
        ...
      depends_on: [S7]
      detail_file: docs/migration/stage-8-frontend-cutover.md

There is **no `status:` on any stage**, and no `active`/`in_progress` field. Stage
activity is not readable; it must be **derived**. A design that assumes a stage status
field would be building on something that does not exist.

Derivable from the per-requirement `status:` field. Measured cross-tab, live:

    S0 cancelled 2 | S0 done 5
    S1 cancelled 2 | S1 done 7
    S2 done 21
    S3 cancelled 1 | S3 done 26
    S4 cancelled 2 | S4 done 14 | S4 pending 20
    S8 cancelled 1 | S8 pending 10
    S9 pending 4
    (115 total; S5/S6/S7 have no requirements — not yet expanded)

Note: **no requirement anywhere is currently `in_progress` or `blocked`.** The file
header declares `pending | in_progress | done | blocked`; `cancelled` occurs in practice
and is undeclared there.

Proposed derivation for CODE-DESIGNER to rule on: a stage is **active** iff at least one
of its requirements has `status` in `{done, in_progress}`. Applied to the table above
this yields S0-S4 active, S8/S9 not active — which is the correct real-world answer, and
retroactively classifies all 21 historical S8/S9 deferrals as **legitimate**. Open
sub-question for the design gate: does `blocked` count as active (work attempted) and
does `cancelled` count (it must NOT — abandonment is not activity)?

### The false-positive class ORCH asked about — it is real

A deferral scoped to a *sibling requirement* rather than a whole stage would be
legitimate inside an active stage, and a bare stage-activity rule would flag it. No such
deferral exists in the corpus today (all 21 were stage-scoped), but the rule must not be
built so it cannot express one. Recommended direction — CODE-DESIGNER to rule:
make the escape hatch **auditable rather than free-form**, e.g. a recognised
`blocked-by: REQ-NNN` prefix inside the existing rationale text, where the named
requirement's own status is machine-checkable and the deferral becomes stale again once
that requirement is `done`. A free-text exemption would reintroduce exactly the
unfalsifiability this issue exists to remove.

### Where it should live — REVIEWER's separate-detector ruling, checked

Upheld, on evidence rather than deference. Three independent reasons:

1. **Different data.** Registration state is decidable from one entry's own lines.
   Staleness requires a cross-entry aggregate (every sibling requirement's `status` in
   the same stage). The existing module's `classify_entry/1` is deliberately per-entry
   and its rules are per-entry plus two trivial aggregates.
2. **Different gating semantics.** The existing module's central design ruling — argued
   and upheld at its own design gate — is that the deferred roster *never* gates. A
   staleness rule must gate. Putting a gating rule on the deferred bucket inside a
   module whose moduledoc states "The deferred count never influences the exit code, at
   any value" would contradict that module's own documented contract.
3. **Different failure class.** "Never registered" vs. "registered-adjacent staleness".

Crucially, separation costs nothing here: `scan/1` and `classify_entry/1` are **already
public** with `@doc`, and the returned entry map **already carries `:stage`**. The new
detector can consume `CheckRequirementsRegistration.scan/1` directly, reusing the
battle-tested attribution/indentation logic rather than writing a second parser that
could drift into its own form-blindness.

**One small, explicitly-named addition** is needed: the entry map carries
`id, line, stage, state, impl_order, rationale, detail` but **not the requirement's
`status:`**, which the staleness derivation needs. Adding `status` to that map is
additive and does not touch the `:deferred` definition, R3, or the exit-code contract.
CODE-DESIGNER to confirm this framing and name it in the design.

### Affected files (expected)

- `lib/mix/tasks/letflow.check_deferral_staleness.ex` (new — name to be confirmed;
  `docs/anti-patterns.md` line 438 warns two branches picking one module name is a real
  rebase collision class)
- `lib/mix/tasks/letflow.check_requirements_registration.ex` (additive `status` field only)
- `mix.exs` (`letflow.check` alias — currently `letflow.check_toolchain`,
  `letflow.check_requirements_registration`, `format --check-formatted`,
  `compile --warnings-as-errors`, `letflow.check.test`)
- `docs/agents/protocols/TASK_QUEUE.md` (state the new staleness rule where the deferral
  convention is written, as ISS-0231 did for R1)
- `lib/letflow/design/iss0258-*.md`, `test/...`, `docs/issues/ISS-0258.yaml`

### Hazard carried forward from ISS-0231

`docs/anti-patterns.md` line 1195: the new module's own moduledoc will contain the
marker forms it recognises, so it must scan `docs/requirements.yaml` only, never `lib/`.

---

## CORRECTION — appended 2026-08-22, after CODE-DESIGN-VALIDATOR (Step 2b)

**This handoff's claim that all 21 historical deferrals were S8-scoped is FALSE, and it
was false when written.** Following ISS-0231's own `correction:` precedent, the wrong
sentence is left in place above rather than rewritten, and corrected here.

CODE-DESIGN-VALIDATOR re-derived the stage assignments instead of inheriting my claim,
and refuted it. I then re-derived it myself rather than accepting the refutation:

    $ git show 75f553d:docs/requirements.yaml > /tmp/old_reqs.yaml
    $ awk '...per-entry stage of each `# impl_order: UNREGISTERED` entry...' /tmp/old_reqs.yaml \
        | sort | uniq -c
          8 S4
          9 S8
          4 S9

**MY ERROR, named exactly.** I ran `grep -n '# impl_order: UNREGISTERED'`, saw 21
identical rationale strings (`-- see the S8 note above`), and read the *rationale text*
as if it were the *stage assignment*. It is not. The rationale was copy-pasted uniformly
across three different stages; only the entries' own `stage:` fields carry the truth,
and I never read them. That is precisely the anti-pattern at `docs/anti-patterns.md`
line 1006, "Re-deriving the count while inheriting the unit being counted" — I re-derived
21 correctly and inherited the wrong unit.

**WHAT IT CHANGES.** S4 held 10 `done` requirements at `75f553d`, so under the design's
own §3.3 rule those 8 S4 deferrals were **STALE**, not legitimate. The corpus splits
**13 legitimate / 8 stale**, not 21/0. My "every real deferral this project has ever had
was stage-scoped [to a not-yet-active stage]" is therefore wrong, and the §1.2 bar it
was used to satisfy was unmet as stated.

**WHAT IT DOES NOT CHANGE — and this is the important part.** The rule is not weakened
by this; it is *vindicated*. Those 8 S4 entries were real, un-actioned debt sitting in an
active stage behind a green gate, later registered by hand under PR #495. **A detector
built to this design would have caught them at the time.** That is exactly the failure
mode ISS-0258 was filed about, found in the historical record rather than hypothesised.

The correction improved the fix: the 8 became the design's only real-world regression
signal (fixture `F-HISTORICAL-S4-STALE`, asserted against `F-S8-SHAPE-LEGIT`), where
before this the entire suite rested on synthetic fixtures because the live corpus has
zero deferred entries.

No other claim in this handoff is affected. The live-state measurements (`0 deferred of
115`), the no-stage-`status`-field finding, and the derivation proposal were each
re-verified independently by the design gate.
