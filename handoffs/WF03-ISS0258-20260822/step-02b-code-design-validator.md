# WF03-ISS0258-20260822 — Step 2b — CODE-DESIGN-VALIDATOR

**Verdict:** PASS — on the design artefact **as corrected in place** by this gate.
**Design artefact:** `lib/letflow/design/iss0258-deferral-staleness-detection.md`
(gate record appended as its §11).
**next_action:** Route to ELIXIR-DEV (WF-03 Step 3). Two OQs are now closed at this gate
(OQ-1, OQ-3) and need not be re-litigated downstream.

Two **MAJOR** findings were raised. Both were fully determined by measurements I ran in
this worktree, neither changes a public signature, a type shape, the exit-code contract,
or the §3.3 ruling, and correcting them in place produced exactly the artefact a bounce to
CODE-DESIGNER would have produced. Per the brief's in-place-correction authority and the
ISS-0231 design-gate precedent (which demoted that design's R5 totality claim and narrowed
its M3 rather than bouncing), the verdict is PASS **on the corrected artefact**. Had either
finding required changing a rule statement or an interface, this would have been a FAIL.

## Acceptance criteria

| criterion | met | where |
|---|---|---|
| surfaces a `DEFERRED` requirement whose stage became active, distinct from one legitimately pending an inactive stage | yes | §3.3 ruling, §3.4 applied to the live corpus, §5 **S1**, §6.2 `classify_deferral/3` → `:stale` \| `:legitimate` \| `:undecidable` |
| wired into a gate a human/CI will see | yes | §D5, slot 3 of the `letflow.check` alias; `mix.exs` in §6.4. Alias contents verified verbatim below. |
| states explicitly WHY separate from `letflow.check_requirements_registration` | yes | §D3 — three inherited reasons re-verified against the shipped source, plus two of the designer's own. Reason 2 (the module's own moduledoc contracts "The deferred count never influences the exit code, at any value") is the strongest and I confirmed the sentence is really there. |

---

## Rulings on (a)–(m)

### (a) `blocked` counts as active — **UPHELD.** OQ-1 closed here, not carried to Step 3.

Measured myself, not inherited:

```
$ grep -cE '^ {4}status: (in_progress|blocked)' docs/requirements.yaml
0
```

So the override against Step 1's `{done, in_progress}` recommendation has **zero live
impact** and is a one-token reversal. On the merits I uphold it. The property §3.3 names is
*"has this stage been engaged with"*, and `blocked` is not reachable from the initial state
without a person starting the work and recording an impediment. The asymmetric-cost
argument also holds **and does not depend on the corpus numbers I refuted in (b)**: a
missed stale deferral is silent and unfalsifiable (the whole issue), a false positive is
named by `REQ-NNN`, printed with its witness ids, and closable in one line.

The one way the argument could fail is if `blocked` were used as a long-lived *parking*
state meaning "nobody is working this" — which would make it behave like `pending` and
bring MS2's reasoning down on it. That is not this project's usage: line 8 of
`docs/requirements.yaml` lists it as a work state alongside `in_progress`, and it has never
been used. Recorded in the design at OQ-1 so a future change of usage has a written trigger.

### (b) The `cancelled` exclusion — **ruling UPHELD, evidence REFUTED. MAJOR finding #1, corrected in place.**

The ruling (`cancelled` is not activity) is right. The measurement offered for it is false,
and so is the design's self-imposed corpus bar. Re-derived from source per
`docs/anti-patterns.md`:

```
$ git show 75f553d:docs/requirements.yaml > /tmp/old.yaml
$ awk '/^requirements:/{r=1;next} !r{next}
       /^  - id: /{if(id!="")print sg" "st" "df; id=$3; st="?"; sg="?"; df="reg"}
       /^ {4}status:/{st=$2} /^ {4}stage:/{sg=$2}
       /# impl_order: UNREGISTERED/{df="DEFERRED"}
       END{if(id!="")print sg" "st" "df}' /tmp/old.yaml | sort | uniq -c
```

The 21 historical deferrals are **not** all S8/S9:

| ids | stage | that stage at `75f553d` | active per §3.3? | verdict |
|---|---|---|---|---|
| REQ-115…REQ-123 (9) | S8 | 10 pending, 1 cancelled | inactive | `:legitimate` |
| REQ-124…REQ-127 (4) | S9 | 4 pending | inactive | `:legitimate` |
| REQ-128…REQ-135 (8) | **S4** | **10 done**, 13 pending, 2 cancelled | **ACTIVE** | **`:stale`** |

Three consequences, all now corrected in the design:

1. **§1.2's bar** — *"the design must retroactively classify those 21 as legitimate or it
   is wrong"* — was **unmet by the design's own ruling**. Left standing, TEST-DESIGNER
   would have written a fixture asserting 21 legitimate and it would have failed.
2. **§3.4's closing sentence** ("retroactively classifies all 21 historical S8/S9 deferrals
   as legitimate") is false. Correct answer: **13 legitimate / 8 stale**.
3. **§3.3's `cancelled` bullet and MS1's row** ("all 21 flag stale" if `cancelled` were
   active) are false in a second, independent way: **S9 has 4 pending and 0 cancelled**, so
   MS1 never moves S9 at all. MS1's real discriminating set is **S8's 9**, and the 8 S4
   deferrals were already stale before the mutant. The refutation of `cancelled` still
   stands directionally — it takes the corpus from 13/8 to 4/17 — but the quoted number was
   wrong, which is exactly the inherited-claim failure the anti-patterns file names.

**Why this is a correction and not a FAIL of the rule:** those 8 S4 entries were genuinely
stale. Their rationale reads `-- see the S8 note above` while they sit in **S4**, a stage
already 10 requirements deep into being worked, and they were subsequently registered by
hand (all 115 entries carry an `impl_order` today). The gate would have caught real debt
weeks early. So the finding *vindicates* the rule while destroying its stated evidence.

I converted it into the design's only piece of real-world regression signal: new fixture
**F-HISTORICAL-S4-STALE**, specified to be asserted **in one group with F-S8-SHAPE-LEGIT**,
because a rule that gets one half of the 13/8 split right and the other wrong is invisible
to either fixture alone.

### (c) Self-exclusion — **coherent, not gameable.** One residual, closed by reporting.

The exclusion is of *the entry under test from its own computation*, not of deferred
entries generally. So two deferred entries A and B in one stage do **not** mutually excuse
each other: A's fold still sees B, and B's still sees A. The mutual-exclusion attack the
brief asked about does not exist. Suppressing a real staleness would require marking the
entry `done`/`in_progress`/`blocked` — a far larger and separately visible lie, and one
that MS10's motivating case (deferred-and-`done`) already exists to keep from self-flagging.

Residual I did find (MINOR): a *lone* deferred entry whose own status is itself active, in a
stage with no other active sibling, reads `:legitimate`. That combination — a requirement
simultaneously worked and marked never-registered — is an anomaly worth seeing, but it is
**registration**-shaped, not staleness-shaped, and a rule for it would widen this gate past
its issue. Corrected by specifying a roster **annotation** (`NOTE: deferred entry is itself
<status>`), printed and never gating — the visible-debt principle applied to the one case
the rule deliberately declines to judge.

### (d) The `blocked-by: REQ-NNN` hatch — **grammar is implementable; expiry is correct; the hatch CAN become a permanent free pass. MAJOR finding #2, corrected in place.**

Grammar: unambiguous enough to build from. `@blocked_by_re` is anchored (`^`), the id is
captured as `(REQ-\d+)\b`, the optional leading `--\s*` handles the historical rationale
form the existing module already produces, and `parse_scope/1`'s contract — *anything not a
well-formed anchored hatch returns `:stage_scoped`, including a malformed near-miss* — means
there is no branch where a near-miss becomes a silent hatch. Expiry rule is correct: blocker
`:done` or `:cancelled` ⇒ stale, which is the right direction (both mean the stated
impediment is over). Dangling id ⇒ S3, self-reference ⇒ S3, free text still required.

**But the four properties are jointly insufficient.** A cycle defeats all of them at once:

```
REQ-A:  # impl_order: UNREGISTERED -- blocked-by: REQ-B -- waiting on the token kernel
REQ-B:  # impl_order: UNREGISTERED -- blocked-by: REQ-A -- waiting on the session store
```

Both ids exist. Neither is a self-reference. Both anchored. Both carry free text. And
**neither blocker will ever be `done` or `cancelled`, precisely because each is waiting on
the other.** The pair licenses itself forever, in an active stage, with nothing to expire.
Longer chains (A→B→C→A) behave identically. That makes D6's central claim — *"not an
exception list; a machine-checkable assertion that expires on its own"* — and invariant
**I5** both false for that case, i.e. ISS-0258's own "green forever" property reintroduced
inside the one construct built to be self-expiring. That is a MAJOR.

Corrected in place: new hard rule **S6** (the `blocked-by:` graph over deferred entries is
acyclic; message names every id on the cycle in order), D6 gains it as a fifth load-bearing
property, I5 amended to say S6 is what makes its sentence true, exit contract widened to
S1–S6, and — a design point ELIXIR-DEV would otherwise have had to guess — **S6 is
explicitly placed in `audit/1`, not `classify_deferral/3`**, since cycle detection is
inherently multi-entry, exactly as `duplicate_id_violations/1` sits outside
`classify_entry/1` in the precedent module. `classify_deferral/3` stays single-entry and
total. New mutant **MS14**, new fixtures **F-HATCH-CYCLE-2** and **F-HATCH-CYCLE-3** (the
three-node case, so nobody passes by special-casing pairs).

### (e) The trailing-comment finding — **count of 8 verified independently; §6.3 closes it.**

```
$ grep -oE '^    status: .*' docs/requirements.yaml | sort | uniq -c
     73     status: done
     34     status: pending
      7     status: cancelled  # MVP-1 milestone dropped, see REQ-101's note
      1     status: cancelled  # MVP-1 milestone dropped by user, commit d41beb0 deleted
$ grep -cE '^ {4}status: [^ ]+ +#' docs/requirements.yaml
8
```

**8**, in two surface variants (7 + 1) — the design quotes only the 7-variant, which is fine
since both are the same shape. 73 + 34 + 8 = 115 = the entry count. Also re-verified the
indentation half: `grep -cE '^ {4}status:'` = **115**, `grep -cE '^ {5,}status:'` = **0**.

§6.3 closes it correctly by mandating the **first whitespace-delimited token**
(`~r/^\s+status:\s*(\S+)/`), mirroring the shipped `@stage_re`, which I confirmed really has
that shape. MS4 targets the rest-of-line mutant, F-STATUS-TRAILING-COMMENT is copied
verbatim from the real file, and T-LIVE-STATUS-TOTAL is genuine (non-vacuous) live signal
for it. The second half of the trap — attributed lines only — is covered by MS5 and
F-STATUS-BLOCK-NOTE. Nothing left open.

### (f) `:undecidable` / unknown-status handling — **mirrors ISS-0231's `:unclassified` defence in fact, not just in claim.**

Present and structurally correct: `normalise_status/1` is total with `:unknown` as its
non-member branch (§6.2), S4 makes `:unknown` a **violation** naming the raw token, I7
states there is no branch anywhere treating an unrecognised status as acceptable, and
`nil` (no `status:` line at all) maps to `:unknown` rather than to a default that passes
(F-NO-STATUS-LINE). Deferred entry with no `stage:` ⇒ `:undecidable` ⇒ **S2 violation**,
explicitly not benefit-of-the-doubt (§3.6). MS6 and MS12 are the mutants; F-TYPO-DOES-NOT-
DEACTIVATE is the sharp one, since it pins the *composed* failure — a typo'd `donee`
silently un-activating a stage and making a stale deferral read legitimate. That is the
ISS-0221 absorption shape and it is closed. This was the check whose absence would have been
an automatic MAJOR; it is present.

### (g) Vacuous-green risk — **re-verified, and the design is honest about it.**

```
$ grep -c 'impl_order: UNREGISTERED' docs/requirements.yaml
0
```

Confirms `115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified`. §7.2
states the consequence in requirement form, not as a caveat: the live corpus has **zero**
signal for S1/S2/S3, no mutant may cite a live-corpus test as its only detector except the
four rows where the corpus genuinely discriminates, and a "live file is green" test is an
over-firing guard rather than evidence the rule works. It names PR #495's M1 incident as the
precedent. D1 mandates a **public content-in pure core** (`audit/1`, plus
`stage_activity/1`, `classify_deferral/3`, `parse_scope/1`, `normalise_status/1`,
`render/1` all public), not a path-in one — which is the only thing that makes the fixture
group possible. T-LIVE-DEFERRED-COUNT-IS-ZERO is specified *with* an explanatory comment so
a future reader knows its change means the rule went load-bearing, not that something
regressed. This is the strongest part of the design.

Note that finding (b) materially improves this picture: F-HISTORICAL-S4-STALE is now real
historical signal where before there was none.

### (h) The mutant traps — **targeted, both mandatory ones correct, three coverage holes found and closed.**

MS3 (drop `:done` from `@active_statuses` ⇒ nothing is ever active ⇒ **ISS-0258 reproduced
inside its own fix**) and MS9 (hatch accepted regardless of blocker status ⇒ never expires)
are both present, both marked mandatory, and both correctly identified as the analogues of
ISS-0231's M1. The other ten target real traps rather than arbitrary breakage — each names
the failure class it reproduces.

Rule-by-rule coverage sweep, which is where I found the holes the brief predicted:

| rule / property | mutant | status |
|---|---|---|
| S1 | MS3, MS11 | ok |
| S2 | MS12 | ok |
| S3 (exists / self / expiry) | MS7, MS8, MS9 | ok |
| S4 | MS6 | ok |
| **S5** | **none** | **HOLE → MS15 added** |
| §3.3 value-by-value | MS1, MS2, MS3 | ok |
| §3.5 self-exclusion | MS10 | ok |
| §6.3 extraction | MS4, MS5 | ok |
| stage identity | MS13 | ok |
| I4 (`:legitimate` never gates) | none, but F-LEGIT-BASIC discriminates directly | acceptable |
| **D6 property 4 (free text required)** | **none** | **HOLE → MS16 added** |
| **D6 acyclicity** | **rule did not exist** | **→ S6 + MS14 added, see (d)** |

MS1's stated effect was also wrong and is corrected — see (b).

### (i) The additive `status` field on `CheckRequirementsRegistration` — **hard constraint honoured in fact.**

Verified against the shipped source rather than against the design's claim. The `:deferred`
path is the `marker != nil` branch of `classify_registration/2`; the addition is a module
attribute, a private `extract_status/1` mirroring `extract_stage/1`, one key in the `base`
map, and one `@type` line. It touches none of `@marker_form_re`, R1–R6, rule ordering,
`render/1`'s "never gates" line, or the exit-code contract. Storing the **raw token, not a
normalised atom** is the right call and is what keeps the old module a dumb, opinion-free
parser — it is already exactly that about `stage`. So "don't silently redefine what deferred
means in that module" holds by construction: nothing in the diff is inside a `:deferred`
code path.

The one risk the design flags — an existing test pattern-matching the entry map exhaustively
— I checked rather than deferring to Step 3:

```
$ grep -nE 'assert .*== %\{|=~ %\{|Map\.keys' test/mix/tasks/letflow_check_requirements_registration_test.exs
(no matches)
```

Zero whole-map equality assertions and no exhaustive entry-map destructuring. The addition
is provably bounded, not just claimed to be. T-REG-STILL-GREEN remains the right belt-and-
braces check.

### (j) Placement — **verified; nothing on record is re-decided.**

Alias read from `mix.exs`, matching D5's quotation exactly:

```
"letflow.check": [
  "letflow.check_toolchain",
  "letflow.check_requirements_registration",
  "format --check-formatted",
  "compile --warnings-as-errors",
  "letflow.check.test"
]
```

Decision record `0005-pin-formatting-toolchain.md` legislates **slot 1 only** — line 205
("It runs **first** in the alias") and line 406 ("prepend `letflow.check_toolchain` as the
**first** entry"). Nothing in 0005 constrains any later index, so slot 3 re-decides nothing
on record. The ordering arguments are sound: after registration so a *shape* break surfaces
as R2/R6 first, before `compile` because both are file-only doc checks. Also confirmed no CI
configuration of any kind exists, so the alias really is the only gate surface and D5's
first argument is not rhetorical.

### (k) OQ-3 — **UPHELD, in scope for this run.** Line-8 legend verified.

```
$ sed -n '8p' docs/requirements.yaml
# Status values: pending | in_progress | done | blocked
```

with 8 entries carrying `status: cancelled`. Ruling it a separate doc issue would mean this
run knowingly ships a gate whose accepted-value set contradicts the legend of the very file
it gates, with the contradiction parked in a queue — and a later reader who "fixes" the
divergence by trusting the legend turns 8 real entries `:unknown` and reds the gate for a
non-reason, which is **MS4's failure mode arriving by a different road**. It is one word in
a comment, changes no requirement data, and is *caused by* this run's rule. It belongs here.
S4's known set is unaffected either way, as the design says.

Consequential MINOR I fixed: §6.4's touched-files table said "no edit to
`docs/requirements.yaml`'s data of any kind", which flatly contradicted OQ-3. Added the row,
scoped to **line 8's comment text only**, with an explicit warning that ELIXIR-DEV must not
read it wider.

### (l) No implementation code — **clean.**

```
$ grep -nE '^\s*(def|defp|defmodule)\b' lib/letflow/design/iss0258-deferral-staleness-detection.md
(no matches)
```

The document carries `@spec`s, `@type`s, module attributes (`@active_statuses`,
`@blocked_by_re`, `@status_re`), rule statements, data shapes, and reasoning. Regex literals
and the active-status list are **constants and data shapes**, not function bodies, and
specifying them exactly is what stops ELIXIR-DEV guessing at the two places where a guess
would be a bug (§6.3's first-token extraction and D6's anchoring). No bodies, no `defmodule`.

### (m) Module-name collision — **distinctive; no collision surface in the fleet.**

```
$ git branch -a --format='%(refname:short)' | grep -iE 'stale|defer|0258'
fix/WF03-ISS0258-20260822          # this run only
$ git ls-files | grep -iE 'stale|deferral'
lib/letflow/design/iss0258-deferral-staleness-detection.md   # this run
web/src/components/ui/StaleVersionError.tsx                  # unrelated frontend
web/tests/... (3 unrelated frontend fixtures)
```

No branch, tracked backend file, or existing Mix task uses `staleness` or `deferral`.
Existing tasks are `letflow.check.test`, `letflow.check_requirements_registration`,
`letflow.check_toolchain`, `letflow.copy_identity_tables`, `letflow.lint_handoffs`, so
`check_*` is the established convention and `_deferral_staleness` is a distinguishing half
no sibling fork has a reason to reach for. `docs/anti-patterns.md` line 438 is satisfied.

---

## Findings summary

| # | severity | finding | disposition |
|---|---|---|---|
| 1 | **MAJOR** | Historical-deferral composition is 9 S8 + 4 S9 + **8 S4**, S4 was active ⇒ **13 legitimate / 8 stale**, not 21 legitimate. §1.2's self-imposed bar was unmet; §3.4, §3.3's `cancelled` bullet and MS1's row were all factually wrong. Rule survives and is vindicated. | Corrected in place; new fixture F-HISTORICAL-S4-STALE turns it into the design's only real-world signal. |
| 2 | **MAJOR** | A `blocked-by:` **cycle** satisfies all four hatch properties and never expires ⇒ permanent free pass ⇒ D6's central claim and I5 both false for that case. | Corrected in place: rule **S6**, D6 fifth property, I5 amended, `audit/1` placement clarified, MS14 + F-HATCH-CYCLE-2/3. |
| 3 | MINOR | **S5** and D6's fourth property had no mutant row — the MR4/MR6 hole class. | MS15, MS16 added. |
| 4 | MINOR | §6.4 contradicted OQ-3 on whether `docs/requirements.yaml` is touched. | Row added, scoped to line 8's comment only. |
| 5 | MINOR | Self-exclusion leaves a lone deferred-and-active entry unjudged. | Roster annotation specified; printed, never gating. |

## For ELIXIR-DEV at Step 3

- Rules are now **S1–S6**. S6 is new and lives in `audit/1`.
- The corpus bar is **13 legitimate / 8 stale**, not 21 legitimate. Do not re-inherit the
  old number if you re-read an earlier revision of the design.
- `docs/requirements.yaml` is touched — **line 8's comment only**, nothing else.
- OQ-1 (`blocked` active) and OQ-3 (legend fix in scope) are **closed at this gate**.
  OQ-2, OQ-4, OQ-5, OQ-6 remain as the design left them; OQ-4 (alias index) and OQ-6
  (stale-by-time, out of scope, ORCH to `register_task` if wanted) are REVIEWER's.

## Unresolved

Nothing blocking. One thing I deliberately did **not** rule on because it is outside a
design gate's remit: whether OQ-6's stage-level idle-pipeline detector should be filed as a
follow-up issue. The design records it correctly; the decision is ORCH's.
