# 0032 — Amendment: bucket rule 2 states its own scope (reaches modules with a genuine A/B alternative; does not reach acceptance-test artefacts)

Status: decided (2026-09-15, `CODE-DESIGNER`, REQ-353), pending `REVIEWER` sign-off
(section below left as an explicit PENDING placeholder for the next pipeline step,
not filled in by `CODE-DESIGNER`).
Owner: `ORCH` (this record amends decision `0022`'s bucket rule 2 by reference; it
produces no implementation and none is scheduled by it).

## Allocation note

REQ-353's own dispatch text pinned this record's number to 0031, on the stated
assumption that 0030 was the highest record on disk at pin time. That pin is
stale: `ls docs/migration/decisions/` at filing time (2026-09-15) shows
`0031-candidate-results-list-scope.md` already exists (filed by REQ-350, a
different decision — candidate-results-list scope — resolved and merged before
this requirement executed). Per REQ-353's own acceptance criteria ("if 0031 is
taken by the time this executes, a third party allocated it, so take the next
genuinely free number"), this record takes **0032**, the next genuinely free
number, and this note propagates that to every citation in this file. Same
stale-pin shape REQ-350 itself recorded for its own number.

## Why this record exists

During S10 P5, `REQ-VALIDATOR` raised that four P5 requirements declared bucket C
on rule 1's test while none carried the rule-2 `REVIEWER` sign-off rule 2
requires. `REVIEWER` adjudicated it on 2026-09-14
(`docs/migration/stage-10-bilimbaga-vertical.md`'s "## REVIEWER sign-off"
section, entry headed "2026-09-14 — REVIEWER, rule-2 adjudication for P5
(REQ-344–REQ-349)", committed in `91a8a8b0`) and found rule 2 does not reach
`REQ-344`, `REQ-346`, `REQ-347` or `REQ-349` — acceptance-test artefacts and an
inventory document — while it does reach `REQ-345`, a mix seed task shipping
executable code. That entry's own closing paragraph, "Consequence for `0022`,"
states the problem in one sentence: "Rule 2 does not state its own scope, which
is why this came up at all," and says the amendment "is to be filed as its own
requirement rather than edited into `0022` in place." This record is that
amendment. Until it lands, the stage-file entry was the governing precedent for
what rule 2 reaches — the wrong home for a rule that binds every future
S10-and-later bucket declaration, since a reader checking what rule 2 means
reads `0022`, not another stage's sign-off log.

## What this record does

Amends decision `0022`'s bucket rule 2 (`## The bucket rule`, rule 2: "Bucket C
requires `REVIEWER` sign-off that A and B were tried first. The sign-off states,
in one sentence each, why the behaviour is not expressible as a definition and
not generalisable as a platform capability.") by stating, as a standing addition
read alongside that text rather than in place of it, the scope that text never
stated:

**Rule 2 reaches a module if and only if its A/B question has a possible
answer** — i.e., the artefact was a genuine candidate to be expressed as a
definition (bucket A) or generalised as a platform capability (bucket B), and
someone can state in one sentence each why it wasn't. An acceptance-test
artefact exercising an already-bucketed surface is never such a candidate, so
rule 2 does not reach it; it is bucket C by rule 1 alone (it cannot be
described without naming the vertical) and is registerable without a rule-2
sign-off. A test fixture that ships executable code (a script, a seed task, a
generator — anything with its own create/read/write logic distinct from the
surface it exercises) is not an acceptance-test artefact in this sense; it is
an ordinary module and rule 2 reaches it exactly as it reaches any other
bucket-C candidate.

## The five clauses, each checked against source wording

**Clause 1 — rule 2 gates modules that had a genuine A/B alternative.**

0022's rule 2, quoted verbatim: *"Bucket C requires `REVIEWER` sign-off that A
and B were tried first. The sign-off states, in one sentence each, why the
behaviour is not expressible as a definition and not generalisable as a
platform capability."*

**Verdict: supported as proposed, no correction needed.** The text names no
scope limiter of its own (it says "bucket C," not "any C artefact including
tests"), but its content is inherently a question about a *behaviour* — "why
the behaviour is not expressible as a definition" presupposes there is a
behaviour for which expressing-as-a-definition and generalising-as-a-capability
are live, answerable alternatives. That is the textual anchor for clause 3
below; nothing here needed correcting.

**Clause 2 — it does not gate acceptance-test artefacts, which take the bucket
of the surface they exercise.**

Read `REQ-306`'s actual entry in `docs/requirements.yaml` (line 18911) rather
than the adjudication's characterisation of it, as required. `REQ-306` — owner
`TEST-DESIGNER`, status `done` — is "Test coverage for `entity_definitions` pack
export/install," and its own `description` states its bucket in these words:
*"bucket: B. Test coverage for a generic pack-format capability — nothing here
names an exam, per 0022's rule 1."* Its acceptance criteria are five ExUnit
test groups (round-trip, name-collision rollback, malformed-entry rejection,
old-pack compatibility, INV-1 isolation) against the pack export/install
surface `REQ-304`/`REQ-305` built. Nowhere in the entry — description or
acceptance criteria — is a rule-2 sign-off requested, written, or referenced;
the entry declares bucket B (the bucket of the pack-format surface under test)
and stops there.

**Verdict: supported as proposed.** `REQ-306` is genuinely the precedent the
adjudication (and REQ-353's dispatch text) says it is — a test-coverage
requirement that took the bucket of the thing it tests, with no separate
rule-2 sign-off anywhere on record. Confirmed by direct reading, not inherited
from the adjudication's summary.

**Clause 3 — the test is whether the A/B question has a possible answer.**

The stage file's actual wording (`stage-10-bilimbaga-vertical.md` line 546-547):
*"A Playwright spec and an inventory document were never candidates for A or B;
the question has no possible answer, so the gate has nothing to bite on."*

**Verdict: needs correction to the exact wording — the substance is supported,
but REQ-353's dispatch text over-quotes.** REQ-353's own description attributes
to the adjudication the sentences *"was never a candidate for either"* (singular
"a Playwright spec") and *"a question with no possible answer is not a gate"*
as if verbatim. Neither string appears in the stage file: the actual text says
artefacts (plural — a spec **and** an inventory document) "were never
candidates for A or B," and says the resulting gap is "the gate has nothing to
bite on," not "is not a gate." The underlying test — an A/B question needs a
possible answer for rule 2 to apply, and an acceptance-test artefact exercising
an already-decided surface never posed one — is real and is what this record
adopts; the wording above is what is actually on record and is what this
record quotes, not the paraphrase.

**Clause 4 — test fixtures that ship executable code stay on the module side
and do need a per-entry sign-off.**

Read `REQ-345`'s actual entry in `docs/requirements.yaml` (line 24461) rather
than the adjudication's characterisation of it, as required. `REQ-345` — owner
`ELIXIR-DEV`, status `done` — is "Provide a deterministic seeded exam fixture
for e2e runs... (S10 P5, test fixture)." Its description declares `bucket: C`
and carries an inline section headed "RULE-2 SIGN-OFF" that cites the same
2026-09-14 adjudication by name and reproduces the one-sentence-each form rule
2 requires: *"Why not A: the fixture's records are bucket-A-shaped (entity
records against pack-defined definitions), but a definition has no execution
semantics — it cannot perform the idempotent create-or-resolve convergence that
re-running the seed requires, which is executable logic. Why not B: a generic
'seed fixture records for a named entity set' mix task is a plausible platform
capability... but it would be built for exactly one caller today; generalising
ahead of a second is the speculative-generality failure mode 0022 exists to
prevent..."*

**Verdict: supported as proposed.** `REQ-345` is a worked example of exactly the
rule this clause states: it ships an executable mix task (`lib/mix/tasks/`,
idempotent create-or-resolve logic distinct from the entity records it writes),
and it already carries a real per-entry sign-off rather than an appeal to a
category. The line this record draws — executable code is on the module side,
a docs/test-directory boundary is not what matters — is exactly where
`REQ-345` sits: its records are pack/definition-shaped (would be A/B-eligible
on their own), but the task wrapping them is not, and that's why rule 2 reached
it while it did not reach the four Playwright/inventory requirements in the
same adjudication.

**Clause 5 — rule 3's metric is directory-scoped, so a rule-2-exempt artefact
adds no inventory row, and a phase adding none records that in prose.**

The stage file's own measurement convention, quoted verbatim (lines 578-587):
*"The metric is directory-scoped — `ls`/`wc -l` over `lib/letflow/exam/*.ex`
and `web/src/pages/exam/*.tsx` — and this file already excludes
`web/src/pages/exam/__tests__/` as 'test files, not modules.' Specs under
`web/tests/e2e/`, a document under `docs/testing/`, and a mix task outside both
directories fall outside the metric, the last of these by directory rather than
by kind. P5 adds no bucket-C inventory rows, and the inventory stays at four
modules under `lib/letflow/exam/` and two screen modules under
`web/src/pages/exam/`... That is an honest reading, not a loophole... A reader
must not read the unchanged inventory as P5 having added nothing exam-specific;
P5's exam-specific output is its ported spec corpus, measured by REQ-348's
parity figure, not by this table."*

**Verdict: supported as proposed.** The stage file's own text already states
both halves this clause requires: the inventory table is scoped by directory
(and explicitly excludes a test directory by name), and the file's own prose
records, in the same passage, that a phase whose inventory stayed flat still
added real exam-specific artefacts, measured elsewhere (the parity figure), so
a reader is told not to mistake an unchanged inventory for unchanged scope.
This record generalises that as a standing rule: an artefact rule 2 does not
reach, because it exercises rather than constitutes bucket-C surface, is by
the same token outside rule 3's directory-scoped metric, and any phase that
adds only such artefacts must say so in prose rather than let a flat inventory
read as "nothing exam-specific happened."

## Class-wide sign-off: considered and declined

A single, category-wide rule-2 sign-off covering "acceptance-test artefacts" as
a class — rather than the per-clause scope statement above — was considered and
**declined**, for the reason the adjudication itself gives, quoted verbatim:
*"A class-wide sign-off was considered and declined: rule 2's force comes from
per-thing justification, and signing off a category would establish that
categories can be waved through."* This record narrows rule 2's scope (states
what kinds of artefact the gate was never able to bite on) rather than
weakening it (waiving the gate for a named category of artefact that *could*
have posed an A/B question). The distinction matters: nothing in this record
exempts a bucket-C module from its own rule-2 sign-off merely because it lives
near tests or fixtures — `REQ-345` (clause 4) is the standing counter-example,
and future test fixtures that ship their own executable logic get the same
per-entry treatment `REQ-345` got, not a pass by category membership.

## The "hard constraint" correction (re-derived independently)

Both `stage-10-bilimbaga-vertical.md` (currently line 331 and line 605 — the
line numbers this requirement's own dispatch text cited, ~296/~550, have
drifted since; re-located by direct grep) and REQ-353's own dispatch text
describe the filing choice ("file as its own requirement, not an in-place
edit") as following "this file's own hard constraint." **That constraint does
not exist as standing text.** Verified three ways against the tree on
2026-09-15, commands and actual output below:

**(1)** `grep -rn -i "hard constraint" docs/` — restricted to
`stage-10-bilimbaga-vertical.md`, returns exactly two hits:

```
docs/migration/stage-10-bilimbaga-vertical.md:331:itself (see this stage file's own hard constraint above).
docs/migration/stage-10-bilimbaga-vertical.md:605:decision `0030`'s Finding 1 and this file's own hard constraint; until it
```

Both are back-references ("see... above," "and this file's own...") to a
constraint, not a statement of one. (The same grep across the rest of `docs/`
also hits several `docs/issues/*.yaml` files and two other spots in
`docs/requirements.yaml`, none of which name or apply to this stage file's
own claimed constraint — they are each that other document's own, unrelated
"hard constraint.")

**(2)** Reading the file's relevant passages directly (lines 320-332 and
595-606) finds no paragraph, under this heading or any other, that actually
states a filing-choice rule. Line 331 sits at the end of a paragraph about
`0030`'s Finding 1 (the stale Lua-grading bucket-A row) and merely points back
up the file; line 605 sits inside the "Consequence for `0022`" paragraph of the
2026-09-14 rule-2 adjudication and does the same thing pointing at `0030`. No
third passage between or around them ever states the rule both are pointing at.

**(3)** `git log --all --oneline -S "hard constraint" --
docs/migration/stage-10-bilimbaga-vertical.md` returns exactly two commits:

```
91a8a8b0 docs(S10): record REVIEWER's rule-2 adjudication for P5
f8258b5b REQ-334: populate stage-10 bucket-C inventory, close S10 P3 (#1332)
```

`f8258b5b` (REQ-334) introduced the line-296-at-the-time back-reference (now
line 331); `91a8a8b0` (the P5 adjudication) introduced the line-550-at-the-time
back-reference (now line 605). Both commits only ever *added a pointer*; the
paragraph either pointer was meant to point at was never written by either
commit or any other.

**The real precedent, cited instead.** Line 331's back-reference appears to
have meant decision `0030`'s own scope fence: `0030`'s "Consequences" section
states, verbatim, *"`0022`'s bucket table is not edited by this record"* — a
genuine, load-bearing precedent for "a disagreement with standing 0022 text is
filed as its own record, with 0022 left byte-identical," but one recorded in
`0030` and in `REVIEWER`'s 2026-09-13 sign-off on it, not in the stage file.
`REVIEWER`'s 2026-09-13 sign-off on `0030` (the same file, "## REVIEWER
sign-off," point 1) states the shape explicitly: *"This is the proper shape: a
disagreement with standing text becomes a decision-record finding, not a quiet
edit and not a footnote in a design doc with no record trail."* This record's
own filing choice — a new record, `0022` left byte-identical — follows that
precedent, not a stage-file rule that was never written.

**Filing-choice justification, stated on its own merits rather than on a
constraint:**

(a) Decision `0030` set the precedent — a gap between `0022`'s text and
platform reality is filed as a named finding in its own record, with `0022`
left byte-identical — and `REVIEWER` signed that shape off on 2026-09-13.

(b) A dated record chain is more legible than silently-revised text: a reader
who has already read `0022` has no way to learn it changed if it changes in
place, whereas a new record appears in the decisions directory's own listing
and dated history.

(c) `0022` is `REVIEWER`-signed as of 2026-09-09 (`stage-10-bilimbaga-vertical.md`
line 488's "2026-09-09 — REVIEWER" entry); editing its signed text in place
would place content that sign-off never reviewed inside a document that reads,
in its entirety, as reviewed. This reason generalises beyond this specific
case — it is the reason any future correction to `0022` (or any other
REVIEWER-signed record) should default to a new, cross-referenced record rather
than an in-place edit.

## Dangling references — reported, not fixed here

The two back-references confirmed above — `stage-10-bilimbaga-vertical.md`
lines 331 and 605, each reading "this file's own hard constraint" and pointing
at a paragraph that was never written — are reported to `ORCH` per
`docs/agents/protocols/ISSUE_QUEUE.md` in this requirement's close-out report,
for `ORCH` to file as a new issue. This record does not edit the stage file
(`DOC-UPDATER`'s file surface, a separate change) and does not self-allocate an
issue id.

## Consequences

- **`0022`'s rule 2 gains a stated scope, read alongside the original text, not
  in place of it.** `docs/migration/decisions/0022-bilimbaga-vertical.md`
  remains byte-identical to `main` — this record touches no line of it.
- **The 2026-09-14 stage-file adjudication stops being the governing precedent
  for what rule 2 reaches.** It remains a correct, dated application of the
  rule to `REQ-344`–`REQ-349` and stands as evidence for this record's clauses,
  but future S10-and-later bucket declarations cite `0022` (as amended by this
  record), not another stage's sign-off log.
- **No requirement's already-registered bucket declaration is reopened by
  this record.** `REQ-306`'s and `REQ-345`'s existing entries are cited as
  evidence, unmodified.
- **No code changes anywhere.** `git diff --name-only` against `main` shows
  only this file as new; no file under `lib/`, `web/`, `priv/` or `test/` is
  touched.

## What this record does not decide

- **Rule 1's or rule 3's substance.** Both stand exactly as `0022` states them;
  this record only narrows what rule 2 reaches.
- **The bucket table** (`0022`'s "Reasoning" § the `BilimBaga` / `Letflow
  mechanism` / `Bucket` table) — untouched.
- **The vertical-not-fork decision** — untouched; out of scope entirely.
- **Decision `0030`'s still-open finding that `0022`'s "Lua/auto-grading rules
  ship in the pack" bucket-A row is stale.** That correction remains unowned.
  This record does not fold it in, does not correct it, and does not assign it
  to a requirement — it is named here only so it is not mistaken for something
  this record resolved.

## SECURITY-REVIEWER sign-off

Not required. This record touches no tenant data path, no HTTP route, no
migration, and no secret — it is a governance amendment to a decision record's
text, with no implementation scheduled by it.

## REVIEWER sign-off

**Verdict: PASS (2026-09-15, `REVIEWER`, REQ-353).**

**1. Scope and title.** The title states this amends `0022`'s bucket rule 2
by stating that rule's scope, and the record's own "What this record does"
and "What this record does not decide" sections keep it there — rule 1, rule
3, the bucket table, and the vertical-not-fork decision are untouched, and
`0030`'s still-open stale-bucket-A-row finding is named, not folded in.

**2. `0022` byte-identical.** Independently re-ran `git diff --name-only main
-- docs/migration/decisions/0022-bilimbaga-vertical.md`: empty output. `0022`
is untouched.

**3. Five clauses, each checked against source.** Independently re-read the
source wording for all five and confirm the record's verdicts:
- Clause 1: `0022` rule 2 quoted correctly; verdict (supported as proposed) is
  right — the text's own "why the behaviour is not expressible..." presupposes
  a live A/B question, which is the anchor clause 3 needs.
- Clause 2: read `REQ-306` directly (`docs/requirements.yaml:18911`) —
  description states verbatim *"bucket: B. Test coverage for a generic
  pack-format capability — nothing here names an exam, per 0022's rule 1,"*
  no rule-2 sign-off anywhere in the entry. Matches the record's claim exactly.
- Clause 3: read `stage-10-bilimbaga-vertical.md` lines 546-547 directly —
  *"A Playwright spec and an inventory document were never candidates for A or
  B; the question has no possible answer, so the gate has nothing to bite
  on."* This is what the record quotes. REQ-353's own dispatch text
  (`docs/requirements.yaml:25670-25673`) does paraphrase it as "was never a
  candidate for either" / "is not a gate" — neither string is in the stage
  file. The record's correction is accurate, not invented.
- Clause 4: read `REQ-345` directly (`docs/requirements.yaml:24461`) — carries
  an inline "RULE-2 SIGN-OFF" section citing the 2026-09-14 adjudication by
  name with the same two one-sentence bullets the record quotes. Matches.
- Clause 5: stage-file measurement convention (lines 578-587) confirmed
  verbatim as quoted; the directory-scoping and the "P5 added no bucket-C
  inventory rows" / parity-figure prose both check out.

**4. Class-wide sign-off declined.** Confirmed against stage-file lines
550-553; the record's quoted reason ("rule 2's force comes from per-thing
justification...") is verbatim.

**5. "Hard constraint" re-derivation.** Independently re-ran `grep -rn -i
"hard constraint" docs/` — the only hits inside
`stage-10-bilimbaga-vertical.md` are lines 331 and 605, confirmed by direct
read to be back-references only, no statement of a rule. Line numbers (331,
605, corrected from the dispatch's stale ~296/~550) are accurate as of this
tree. The record correctly declines to cite a nonexistent stage-file
constraint and instead cites decision `0030`'s "Consequences" scope fence
(*"`0022`'s bucket table is not edited by this record"*, `0030` line 211) and
`REVIEWER`'s 2026-09-13 sign-off on `0030` (*"This is the proper shape: a
disagreement with standing text becomes a decision-record finding, not a
quiet edit..."*, `0030` line 418) — both verified verbatim against `0030`
directly, not taken from this record's characterization.

**6. Dangling references reported, not fixed.** `ISS-0675.yaml` exists,
correctly scoped to `stage-10-bilimbaga-vertical.md` only (`DOC-UPDATER`'s
surface), and `git diff --name-only` confirms the stage file is untouched by
this requirement.

**7. SECURITY-REVIEWER skip.** Correctly justified — no tenant data path, no
route, no migration, no secret; a governance-text-only change with no
implementation scheduled. Confirmed by `git status`/`git diff --name-only`:
only this file is new, nothing under `lib/`, `web/`, `priv/`, or `test/`.

**No idiom, supervision, or scope-creep concerns** — this is a docs-only
decision record; none of the OTP/supervision/type-safety checks apply. No
scope creep: the record narrows an existing gate's stated scope rather than
introducing new abstraction ahead of need.
