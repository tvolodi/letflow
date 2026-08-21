# Worked re-draft — validating ISS-0198's structure rule against a real dispatch

**This file is deliberately `.md`, not `.json`.** It is a worked example, not a handoff. A
handoff-shaped JSON file under `handoffs/` would be picked up by ISS-0191's linter and by
any future corpus measurement as a real dispatch, which it is not.

**Subject:** `handoffs/WF03-ISS0109-20260821/step-02-code-designer.json` — the corpus
maximum `task.description` at **12,187 characters**, and the file the ISS-0198 diagnosis
quotes as the cite-and-also-restate exemplar. Re-drafted here against
`HANDOFF_PROTOCOL.md` §2's structure rule, produced 2026-08-21 in run
`WF03-ISS0198-20260821`.

## Measurement

| | `task.description` | `acceptance_criteria` (8 items) | H-SIZE-1 | H-SIZE-2 |
|---|---|---|---|---|
| **Before** | 12,187 chars | 1,589 chars | **flags** (>6,000 and names `iss064-orphaned-tenant-schemas-fix.md`, `step-01-issue-fixer-diagnose.json`) | no (13,776 > 400) |
| **After** | **7,333 chars** | 1,589 chars — **byte-identical, unchanged** | **still flags** (7,333 > 6,000, and it names its `artifacts_in` files by design) | no (8,922 > 400) |

All figures measured from the files, not estimated. **The re-draft still trips H-SIZE-1,
and that is reported rather than fixed** — see "What this validates" below.

Removed: 4,854 characters, **all of it restatement of files already in `artifacts_in`**.
Nothing on the instruction side was cut: every scope item, every mandatory design section,
every constraint, every rework directive and every acceptance criterion survives verbatim
or near-verbatim. The eight acceptance criteria are copied through unchanged — a re-draft
that altered them would be changing the step, not its dispatch.

## What was removed, and where it already lived

| Removed from `task.description` | Already present in `artifacts_in` |
|---|---|
| "THE DIAGNOSIS IN ONE PARAGRAPH" — a full restatement of Step 1's refutation of ISS-0109's stated mechanism | `step-01-issue-fixer-diagnose.json` → `result.summary`, in full and with the evidence |
| "THE SPECIFIC LEAD THE DESIGN MUST RESOLVE" — restates Step 1's `re_select_registration/1` finding | same file, same field |
| "FIRST, THE PART THAT IS NOT REWORK" — restates what the gate confirmed and how | `step-02b-code-design-validator.json` → `result.summary` |
| The two-numbered blocking-defect narrative, including its quoted `tenant.ex:56` field line and the changeset error the validator got | `step-02b-code-design-validator.json` → `result.issues` |
| Per-issue one-line summaries of ISS-0110/0111/0113/0107 | `docs/issues/ISS-01{07,10,11,13}.yaml` |

`step-02b-code-design-validator.json` was **added to `artifacts_in`** in the re-draft. The
original restated that file at length while not listing it at all — the failure the
structure rule's table is aimed at.

## The re-drafted `task.description`

```
WF-03 Step 2 -- FIX DESIGN for ISS-0109 (GH#358), REWORK ITERATION 1 of 3. Dispatched
2026-08-21T01:51:35Z after CODE-DESIGN-VALIDATOR returned FAIL on step-02b.

READ FIRST, in this order, and do not re-derive any of it:
 1. step-02b-code-design-validator.json -- result.summary in full, then result.issues.
    This is the gate you are answering. Sections 2, 5, 7 and 8 of your design PASSED it;
    the summary says what it re-derived and how. Do not re-open them, do not "improve"
    them, and do not restate their conclusions differently.
 2. step-01-issue-fixer-diagnose.json -- result.summary in full. It is authoritative and
    it OVERTURNS ISS-0109's own stated mechanism, so read it before the issue record, not
    after. Two things in it are load-bearing for this design and you must not contradict
    them: the fault class it establishes, and the specific lead it identifies in
    lib/letflow/tenant_provisioning.ex:455-490.
 3. step-005-issue-fixer-registry-lookup.json, then docs/issues/ISS-0109.yaml.

DELIVERABLE: a design artefact at lib/letflow/design/iss0109-<slug>.md, naming convention
matching lib/letflow/design/iss064-orphaned-tenant-schemas-fix.md. DESIGN ONLY -- no
implementation code. ELIXIR-DEV implements it in Step 3.

FIX THE BLOCKING DEFECT. result.issues[0] of step-02b names it precisely, with the source
it was verified against and the changeset error the validator got by running the insert.
It is in SS3.2's opts contract and it is real: an implementer following SS3.2 literally
would write a helper that raises on every tenant insert. Verify the corrected contract
against lib/letflow/identity/tenant.ex and the two fixture call sites (promotion_test.exs
and promotion_assertion_rerun_test.exs) BEFORE you write it -- this defect was a reading
error about real source, so do not fix it with another reading of the same kind.
Confine the diff to SS3.2, plus any cross-reference elsewhere that literally names the
status/oidc_mode contract and would otherwise contradict the corrected SS3.2 -- grep for
it rather than assuming there is none.

ALSO IN SS3.2: disambiguate capture_schema_state/1's failure boundary -- when a per-field
capture failure yields nil for that field, versus when the whole call returns
{:error, {:capture_failed, _}}. As written, two implementers would guess differently.

THE TWO MINOR GATE OBSERVATIONS (step-02b result.issues[1] and [2]): address both in
place rather than arguing with them. Both concern SS2.2's wording about req022, and both
narrow a claim rather than change a decision -- the decision to leave production code
alone is unaffected and stands.

YOUR FIRST SUBSTANTIVE JOB, unchanged from the original dispatch: establish FROM THE CODE,
with file:line evidence, whether the Step 1 lead is a REAL defect in
lib/letflow/tenant_provisioning.ex or whether some caller already guarantees the
invariant. This determines the shape of everything else:
 - If REAL: the primary deliverable is the production-side fix -- what invariant the
   registration/replay path must guarantee before returning {:ok, _}, and what it must
   return instead when the invariant does not hold. This makes the change a
   TENANT-DATA-PATH change, so SECURITY-REVIEWER gates it in Step 3: design accordingly,
   with no cross-tenant leakage through a new error value and no new query that is not
   tenant-scoped.
 - If NOT: say so plainly and design only the test-side items. A design that invents a
   production change to look substantial is worse than one reporting the code is correct.

SCOPE -- IN:
 (C) The completeness invariant above, at whichever layer you establish is correct
     (production path and/or fixture). Include the post-provision completeness assertion,
     so a partially-migrated tenant schema fails loudly AT the fixture with the state
     named, rather than 500 lines later as an opaque 42P01.
 (A) A shared test/support helper providing the tenant fixture for the two modules
     ISS-0109 names, which on a provisioning/replay failure captures in ONE shot: whether
     the tenant_schemas row is present, whether the schema is present in
     information_schema.schemata, provisioned_at, the BEAM's utc_now at failure time, and
     the table list actually present in the schema. This is the artefact that converts the
     next occurrence from unattributable to attributable.
 (B) Teardown logging distinguishable in the log from a mid-test drop -- the ambiguity
     that caused the original misdiagnosis. One identifiable log line, not a logging
     framework.

SCOPE -- OUT. Do NOT design fixes for these, and do NOT let the design's rationale depend
on any of them being fixed. Each is already filed; read the issue record if you need to
know what it covers: ISS-0110/GH#364, ISS-0111/GH#365, ISS-0113/GH#367, ISS-0107/GH#357,
and ISS-0112/GH#366. ISS-0112 carries one binding instruction for you: THIS RUN ADOPTS
THE HELPER IN EXACTLY THE TWO MODULES ISS-0109 NAMES
(test/letflow/definitions/promotion_test.exs and
test/letflow/definitions/promotion_assertion_rerun_test.exs). Design the helper so the
other 39 copy-paste sites CAN migrate later; do not migrate them here.

MANDATORY DESIGN SECTION -- FAIL-FIRST PROVABILITY. WF-03 Step 4 requires a regression
test that FAILS against pre-fix code and PASSES against post-fix code, and an
intermittent unreproduced failure cannot be regression-tested by waiting for it to recur.
So for EVERY behaviour change the design proposes, state concretely how a test can be made
to fail deterministically against pre-fix code -- e.g. by constructing the exact broken
state (a tenant_schemas row whose schema was dropped; a schema missing one expected table)
and asserting pre-fix code returns {:ok, _} where post-fix code must not. If a proposed
change CANNOT be shown to fail first, say so explicitly and justify why it still belongs
-- do not quietly include it. TEST-DESIGNER builds from this section, so it must be
specific enough to build from.

MANDATORY DESIGN SECTION -- WHAT THIS DOES AND DOES NOT CLOSE. State plainly whether
shipping this makes ISS-0109 genuinely FIXED (a root cause removed) or INSTRUMENTED (the
next occurrence becomes attributable, cause still unknown). ORCH decides the issue's final
status at Step 5 from your answer. An honest "instrumented, not fixed" is correct and
acceptable; an overstated one would put a false 'resolved' into a registry six other
issues cross-reference. The gate specifically checked this verdict in both directions
last iteration -- keep it honest.

CONSTRAINTS:
 - Design artefact only. No implementation code. Interfaces, @specs, state/schema shapes,
   invariants, failure modes.
 - Do not contradict lib/letflow/design/iss064-orphaned-tenant-schemas-fix.md or any
   docs/migration/decisions/ record. If the design appears to need to, STOP and flag it
   for REVIEWER sign-off rather than diverging (core-directives.md).
 - Toolchain note: this host runs Elixir 1.20.3/OTP 29 against a .tool-versions pin of
   1.18.3-otp-27 (ISS-0106, already filed, not yours). `mix format --check-formatted` and
   `mix compile --warnings-as-errors` fail on main itself for that reason. Use plain
   `mix compile` if you need to check anything.
 - Branch feature/WF03-ISS0109-20260821 is yours. Commit by explicit filename, never
   `git add -A`.
```

## Acceptance criteria — unchanged

All 8 items carry through byte-for-byte from
`handoffs/WF03-ISS0109-20260821/step-02-code-designer.json`'s
`task.acceptance_criteria` (1,589 chars total, verified by comparing the two lists
directly). They are not reproduced here, for the same reason the re-draft above does not
reproduce the diagnosis.

## What this validates, and what it does not

**Validates:** the rule is applicable to a real dispatch at the corpus maximum, and
applying it removes only duplication. A CODE-DESIGNER receiving the re-draft is told
everything it was told before about *what to do*; what it is no longer told twice is what
Step 1 and Step 2b found, which it is instructed to read in full at the source.

**The most useful finding here is the one that did not go to plan.** The re-draft was
expected to fall under H-SIZE-1's 6,000 WARN threshold. It does not — 7,333 chars, and it
names its `artifacts_in` files deliberately, so it flags on both clauses. Getting it under
6,000 would mean cutting scope items, mandatory design sections or constraints, i.e.
cutting instruction, which is exactly the truncation failure mode H-SIZE-2 exists to catch
and which `HANDOFF_PROTOCOL.md` §6 forbids. So the number is reported as measured and the
draft is left alone.

That is the rule behaving correctly, not failing. **H-SIZE-1 is a WARN, not a gate, and
6,000 is not a budget any dispatch must meet** — a genuinely large step with a lot of
scope legitimately needs a large dispatch. What the WARN selects is a tail worth a human
or reviewer glance; what it establishes on inspection here is that the remaining 7,333
chars are instruction, and the 4,854 that went were duplication. A version of this rule
that made the flag a failure would have forced the wrong edit, which is why it does not.

**Does not validate:** that the re-drafted dispatch would have produced the same design.
That is unknowable without re-running the step, and claiming it would be speculation. The
honest claim is narrower — the instruction content is preserved and the acceptance
criteria are identical, so the step is judged against exactly the same bar.

**`context.source_text` was NOT used in this re-draft**, and that is the expected outcome
rather than an omission: this dispatch needs the agent to *act on* Step 1 and Step 2b, not
to have their exact wording in front of it, so citing the paths is sufficient. The field
is for the case where exact wording is load-bearing — a clause being amended, a line being
quoted back.
