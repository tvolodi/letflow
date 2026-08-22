# ISS-0258 — Deferral-staleness detection

**Issue:** ISS-0258 (WF-03, run `WF03-ISS0258-20260822`, queue task 258, GH #500)
**Owner of implementation:** `ELIXIR-DEV`
**Author:** `CODE-DESIGNER`
**Precedent this deliberately copies:** `lib/letflow/design/iss0231-requirement-registration-drift-detection.md`
— same repo, same author intent, same failure class one level down.

No implementation code appears in this document. Signatures, type shapes, rule
statements, and decisions only.

---

## 1. What is being fixed (inherited from Step 1, spot-checked, not re-derived)

`mix letflow.check_requirements_registration` (ISS-0231) classifies every requirement
into `:registered | :deferred | :neither | :unclassified`. The only rule touching
`:deferred` is **R3**, which fires exactly when the rationale is `nil` or `""`, and the
roster header is explicit that the bucket never gates:

> `DEFERRED (visible debt -- always reported, never gates)`

So *any* non-empty rationale satisfies R3 forever. There is no time dimension, no
re-evaluation against the world, and no field anywhere that could expire. A requirement
deferred with a once-true reason stays green after that reason stops being true.

That is the ISS-0221 failure mode — a validated-looking requirement `get_next_task`
never returns, whose only symptom is an idle pipeline — displaced one layer up.
`UNREGISTERED` is now watched. **`DEFERRED` is the state nothing watches.**

The root cause is not a bug in ISS-0231's logic. The detector is correct for the failure
class it was scoped to. The root cause is a **missing invariant**: the project has a
written rule for *whether a deferral is documented* (TASK_QUEUE.md: marker plus non-empty
rationale, mandatory) and **no rule at all for whether a deferral is still justified**.
R3 checks the presence of a reason; nothing checks the reason's continued truth. Free
text is unfalsifiable by construction.

### 1.1 Measurements I made myself in this worktree (2026-08-22)

Every number below was produced by a command run in this worktree on branch
`fix/WF03-ISS0258-20260822`, not copied from the Step-1 handoff.

| measurement | command | value |
|---|---|---|
| the registration gate's own report | `mix letflow.check_requirements_registration` | `115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified`, `DEFERRED ...: none` |
| deferral markers in the corpus | `grep -c 'impl_order: UNREGISTERED' docs/requirements.yaml` | **0** |
| `- id:` lines in the whole file | `grep -cE '^  - id: ' docs/requirements.yaml` | 125 (115 requirements + 10 `stages:` entries — confirms §4.1's section guard) |
| requirement `status:` lines | `grep -cE '^ {4,}status:' docs/requirements.yaml` | **115** — exactly one per entry |
| `status:` lines deeper than 4 spaces | `grep -cE '^ {5,}status:' docs/requirements.yaml` | **0** |
| distinct status surface forms | `grep -oE '^    status: .*' \| sort \| uniq -c` | `73 done`, `34 pending`, `8 cancelled` — **and 8 of those 8 carry a trailing `# ...` comment** (see §6.3, trap MS4) |
| stage/status cross-tab | awk over the entry blocks | S0 `2 cancelled 5 done`; S1 `2 cancelled 7 done`; S2 `21 done`; S3 `1 cancelled 26 done`; S4 `2 cancelled 14 done 20 pending`; S8 `1 cancelled 10 pending`; S9 `4 pending` |
| CI configuration | `ls .github`, `.gitlab-ci.yml`, `.circleci` | **none of any kind exists** |

Two consequences that shape everything below:

- **The deferred set is genuinely EMPTY.** A staleness gate is *vacuously green* on
  today's `main`, so it can ship as a hard gate with **no grandfather clause and no
  exception list** (§8, I5). Any future red is a new fact.
- **The live corpus therefore provides ZERO regression signal for the staleness rule
  itself.** This is exactly the situation ISS-0231 hit when PR #495 emptied the deferred
  set and its M1 mutant became invisible to any live-corpus test. All discriminating
  power for the staleness half must come from hermetic fixture strings (§7).

### 1.2 What a real deferral looked like

All 21 pre-PR#495 deferrals carried one identical rationale:

```
    # impl_order: UNREGISTERED -- see the S8 note above
```

Every real deferral this project has ever had was **stage-scoped** — a pointer to a
stage-level block note deferring a whole S8/S9/S4 batch pending the stage. That is direct
corpus evidence that a stage-activity signal is the right primary axis (§3), and it means
the design must retroactively classify those 21 as **legitimate** or it is wrong.

---

## 2. Acceptance criteria → where each is answered

| ISS-0258 acceptance criterion | answered in |
|---|---|
| A mechanism surfaces a `DEFERRED` requirement whose stage has since become active, **distinct from** one legitimately deferred pending a not-yet-active stage | §3 (activity derivation), §5 rule **S1**, §6.2 `classify_deferral/3` returning `:stale` vs `:legitimate` |
| Wired into an actual gate or report a human/CI will see — not built and left unwired | §4 **D5** (slot 3 of the `letflow.check` alias) and §6.4 (`mix.exs` in the touched-files table) |
| The design states explicitly WHY this is a separate detector rather than an extension | §4 **D3**, independently re-derived, with two reasons of my own added |

---

## 3. What counts as stale — the activity derivation (**RULING**)

### 3.1 "Active stage" is not a readable field

Verified against the `stages:` block. A stage entry carries exactly `id`, `name`,
`description`, `depends_on`, `detail_file`. **There is no `status:` on any stage**, and
no `active`/`in_progress` field. Stage activity is not readable — it must be **derived**
from the per-requirement `status:` values of the requirements *in* that stage. A design
that assumed a stage status field would be building on something that does not exist.

### 3.2 The status lattice

```
@type status :: :pending | :in_progress | :done | :blocked | :cancelled | :unknown
```

`docs/requirements.yaml` line 8 declares `pending | in_progress | done | blocked`.
`cancelled` occurs 8 times in practice and is **undeclared there** — see OQ-3.
`:unknown` is this design's own totality bucket for anything else, and it **hard-fails**
(§5, S4). That is the direct structural descendant of ISS-0231's `:unclassified`: an
unrecognised value must land in a *failing* bucket, never be absorbed into a passing one.

### 3.3 The ruling

> **A stage is `:active` iff at least one requirement assigned to that stage — excluding
> the requirement currently under test — has `status` in `{:done, :in_progress,
> :blocked}`. `:pending` and `:cancelled` do not confer activity. `:unknown` confers
> nothing and separately hard-fails.**

`@active_statuses [:done, :in_progress, :blocked]`

Justification, status by status:

- **`:done` — active.** Load-bearing. Work in the stage completed; the stage is
  demonstrably underway. Removing `:done` from the set makes the derivation vacuous and
  reproduces ISS-0258 *inside its own fix* (mutant MS3, §7.3).
- **`:in_progress` — active.** Definitionally. Measured: **zero requirements are
  currently `in_progress`**, so this contributes nothing today; it is there so the
  derivation is not silently wrong the first time one appears.
- **`:blocked` — active. This overrides the Step-1 recommendation, deliberately.**
  The Step-1 diagnosis proposed `{done, in_progress}` and asked the design gate to rule
  on `blocked`. I rule it **in**, for two reasons. First, the property being tested is
  *"has this stage been engaged with"*, and `blocked` is only reachable by someone
  starting the work and recording an impediment — that is engagement, not idleness.
  Second, the error costs are asymmetric: a **false negative** (a stale deferral the
  gate misses) is the exact, silent, unfalsifiable failure class this issue exists to
  remove, while a **false positive** is loud, named by `REQ-NNN`, and closable in one
  line by either re-scoping the rationale or using the §3.5 hatch. When in doubt,
  surface. Measured cost of this override today: **zero — no requirement anywhere is
  currently `blocked`.** It is a one-token reversal if REVIEWER disagrees (OQ-1).
- **`:pending` — NOT active.** `pending` is the initial state. It carries no information
  that work began. Counting it would make every stage that has any requirement at all
  active, which flags every deferral that has ever existed (mutant MS2).
- **`:cancelled` — NOT active. Abandonment is not activity.** This is not a judgement
  call; it is measured. S8 holds `1 cancelled + 10 pending`. If `cancelled` conferred
  activity, S8 would be "active" and **all 21 historical deferrals — every real deferral
  this project has ever had — would be flagged stale**. A rule that is wrong about 21 of
  21 known-good cases is refuted (mutant MS1).

### 3.4 Applied to the live corpus (the correctness check on the rule itself)

| stage | statuses present | derived |
|---|---|---|
| S0 | 5 done, 2 cancelled | **active** |
| S1 | 7 done, 2 cancelled | **active** |
| S2 | 21 done | **active** |
| S3 | 26 done, 1 cancelled | **active** |
| S4 | 14 done, 20 pending, 2 cancelled | **active** |
| S5, S6, S7 | *no requirements — stage not yet expanded* | **inactive** (empty stage) |
| S8 | 10 pending, 1 cancelled | **inactive** |
| S9 | 4 pending | **inactive** |

This is the correct real-world answer, and it retroactively classifies all 21 historical
S8/S9 deferrals as **legitimate** — the corpus check §1.2 demanded.

A stage with **no** requirements (S5/S6/S7) is `:inactive` by the same rule, not by a
special case: the empty set contains no active status. No exception is written for it.

### 3.5 Self-exclusion (a subtle case the brief did not name)

The entry under test is **excluded from its own stage's activity set**. Without this, a
deferred requirement that is itself `done` would activate its own stage and flag itself —
a self-reference paradox that produces an unfixable red. It costs one filter and removes
the case entirely (mutant MS10).

### 3.6 Undecidable deferrals

A deferred entry whose `stage:` field is absent (`stage == nil`) cannot have its
staleness decided at all. It is **not** given the benefit of the doubt — that would be a
silent exemption, which is the whole failure class here. It is a violation in its own
right (§5, **S2**).

---

## 4. Design decisions

### D1 — A separate Mix task, pure core public, content-in

`Mix.Tasks.Letflow.CheckDeferralStaleness`, one module holding both the pure audit core
and the CLI wrapper, following `letflow.lint_handoffs` / `check_requirements_registration`
precedent: no new `Letflow.*` application namespace is invented for pipeline meta-tooling,
which is not domain code.

The core is **public** and takes **content, not a path** — for the reason §1.1 measured:
with zero deferred entries live, hermetic fixture strings are the *entire* regression
value. Fixture-level access is not a convenience here, it is the only thing that can
catch the bug this fix exists to prevent.

### D2 — Name: `letflow.check_deferral_staleness` (**collision ruling**)

`docs/anti-patterns.md` line 438 ("Two branches picking the same module name is a real
rebase-time collision class") is live tonight: many sibling forks are landing. Measured
in this worktree, the in-flight branches are `feature/WF02-REQ077`, `feature/WF02-REQ078`,
and `fix/WF03-ISS0224 / 0226 / 0227 / 0229 / 0230 / 0231`. **None of them concerns
deferrals, staleness, or expiry** — this is the only work item in the fleet whose subject
is the deferral bucket, so the semantic name is not one another branch has a reason to
reach for. The collision surface is the exact file path
`lib/mix/tasks/letflow.check_deferral_staleness.ex`; existing tasks are
`letflow.check.test`, `letflow.check_requirements_registration`, `letflow.check_toolchain`,
`letflow.copy_identity_tables`, `letflow.lint_handoffs`, so the `check_*` prefix is the
established convention and `_deferral_staleness` is the distinguishing half. The name was
also published in this run's Step-1 handoff before any code was written, so it is visible
in the shared branch namespace rather than invented at implementation time.

### D3 — Separate detector, not an extension (**independently re-derived**)

REVIEWER ruled separate; Step 1 upheld it with three reasons. I verified all three and
add two of my own. **Verdict: separate — upheld.**

1. **Different data shape.** Registration state is decidable from one entry's own lines;
   `classify_entry/1` is deliberately per-entry. Staleness needs a *cross-entry
   aggregate* — every sibling requirement's `status` in the same stage — which no
   per-entry classifier can express. *Verified* against the shipped module: its rules are
   per-entry plus two trivial file-level aggregates (R4 duplicate ids, R5 totality),
   neither of which is a grouped fold.
2. **Different gating semantics — the strongest reason.** The shipped module's moduledoc
   states its contract in words: *"The deferred count never influences the exit code, at
   any value."* That ruling was argued and upheld at its own design gate (D3 there: a
   gate permanently red for a known, documented, intended state gets ignored). A
   staleness rule **must** gate. Adding a gating rule on the deferred bucket inside that
   module would contradict the module's own written contract, and the reader could no
   longer trust the sentence. *Verified* by reading lines 71–90 and 369–400 of the
   shipped file.
3. **Different failure class.** "Never registered" vs. "registered-adjacent staleness".
4. **(mine) Different inputs, therefore different blast radius on a red run.** The
   registration check is a function of the file's `impl_order` lines; the staleness check
   is a function of its `status` lines — a field the registration check has, by design,
   no business rules about. Merged, one exit code would cover two independent invariants,
   and a red run would force the reader to disambiguate *which* invariant broke before
   knowing whether the file changed or the world did.
5. **(mine) Merging couples the two mutant sets.** Every staleness fixture would have to
   be a corpus that also satisfies R1–R6, so a change to the registration rules could
   turn a staleness fixture red for an unrelated reason. Separation keeps each module's
   mutant set independent — which matters more than usual here, because §7 is the only
   place this fix has any regression value at all.

**The honest cost of separation** — two tasks reading the same file, and two report
blocks on the gate surface — is real but small, and it is bounded by D4's reuse: only one
parser exists.

### D4 — Reuse `CheckRequirementsRegistration.scan/1`; one bounded, named addition (**RULING**)

**Rule: reuse. Do not write a second parser.**

`scan/1` and `classify_entry/1` are already `@doc`'d public functions, the returned entry
map already carries `:stage`, and the parser already encodes hard-won knowledge — the
`requirements:` section guard, the entry-boundary rule, and above all the ≥4-space
attribution rule that keeps 2-space prose block notes out of entries. A second parser
would drift into its own form-blindness, which is the *original* ISS-0231 root cause
recurring by duplication.

**The one addition, named explicitly as a bounded change:**

> `CheckRequirementsRegistration`'s `entry()` map gains a `status: String.t() | nil` key,
> extracted from the entry's attributed lines by a `@status_re` that is a direct copy of
> the existing `@stage_re`'s shape — first whitespace-delimited token only.

Scope of that change, stated so the Step-3 gate can check it:

- It adds one module attribute, one private extractor mirroring `extract_stage/1`, one
  map key, and one `@type` line.
- It **stores the raw token, not a normalised atom.** All semantic interpretation of
  status values lives in the new module. The old module stays a dumb, opinion-free
  parser, exactly as it already is about `stage`.
- It touches **none** of: the `:deferred` definition, `@marker_form_re`, R1–R6, rule
  ordering, `render/1`'s "never gates" line, or the exit-code contract. The run's hard
  constraint — *don't silently redefine what deferred means in that module* — is
  satisfied by construction, since nothing in the diff is inside a `:deferred` code path.
- Existing tests of that module must remain green unchanged. Any that pattern-match the
  entry map exhaustively (`%{id: _, line: _, stage: _, ...} = e` with no rest) would
  break; a map-key assertion style would not. ELIXIR-DEV verifies this at Step 3.

Rejected alternative — passing a separate status map parsed by the new module from the
same content — because it means two things walk the same lines with two different
attribution rules, which is the duplication hazard above wearing a different hat.

### D5 — Placement: slot 3 of the `letflow.check` alias (**RULING**)

Current alias, read from `mix.exs`:

```
"letflow.check": [
  "letflow.check_toolchain",
  "letflow.check_requirements_registration",
  "format --check-formatted",
  "compile --warnings-as-errors",
  "letflow.check.test"
]
```

**Ruling: insert `letflow.check_deferral_staleness` at position 3, immediately after
`letflow.check_requirements_registration` and before `format --check-formatted`.**

1. **A check nobody runs is not a check, and there is no other surface.** I re-verified
   §1.1: `.github` does not exist, nor `.gitlab-ci.yml`, nor `.circleci`. `mix
   letflow.check` is not merely the primary gate surface, it is the **only** one. The
   local counter-example is `mix letflow.lint_handoffs` — built, correct, wired into
   nothing, and consequently never run. Leaving this unwired fails ISS-0258's second
   acceptance criterion outright.
2. **Adjacency to its data source.** It consumes the same parse of the same file; the two
   report blocks belong next to each other in the output, and a reader debugging a red
   run sees registration state and deferral state in one place.
3. **Ordering after registration is deliberate, not arbitrary.** If the file's *shape*
   broke, `check_requirements_registration`'s R2/R6 must be the first error the reader
   sees. A staleness report derived from a corpus whose shape is already suspect would be
   a confusing first failure. Registration is a precondition for staleness being
   meaningful, so it runs first.
4. **Before `compile`.** Both are file-only doc checks needing no compiled application
   code beyond the task module itself, so both give fast feedback ahead of the slow
   steps. This preserves the ordering property ISS-0106 measured for
   `compile --warnings-as-errors` (an already-compiled project still exits 1 from that
   step) — nothing about inserting another pre-compile doc check disturbs it.
5. **`docs/migration/decisions/0005` legislates slot 1 only**, so this re-decides nothing
   on record. Per ISS-0231's OQ-2 precedent, the design is indifferent to the exact index
   and firm only about *being in the alias at all*; if REVIEWER prefers another slot, say
   so at the Step-3 gate.

### D6 — The escape hatch: `blocked-by: REQ-NNN`, machine-checkable (**RULING**)

**The false-positive class is real.** A deferral scoped to a sibling *requirement* rather
than to a whole stage would be legitimate inside an active stage, and a bare
stage-activity rule flags it. No such deferral exists in the corpus today — all 21 were
stage-scoped — but the rule must be able to express one, or the first legitimate case
will be "fixed" by weakening the gate.

**Ruling: accept the Step-1 direction, with a tightened grammar.** The hatch is a
recognised *scope prefix* parsed out of the existing rationale text — no new field, no
schema change to `docs/requirements.yaml`:

```
    # impl_order: UNREGISTERED -- blocked-by: REQ-042 -- <free-text rationale>
```

Parsed from the `rationale` string the existing module already produces (which begins
`-- ` for the historical form), anchored at its start:

```
@blocked_by_re ~r/^(?:--\s*)?blocked-by:\s*(REQ-\d+)\b\s*(?:--\s*)?(\S.*)?$/
```

Four properties, each load-bearing:

- **Anchored to the start of the rationale.** An unanchored match would let prose —
  including a rationale that merely *mentions* the form — activate the hatch. That is
  ISS-0231's M8 absorption bug wearing this issue's clothes (mutant MS7).
- **The named id must exist in the corpus.** A dangling `blocked-by: REQ-999` would be a
  permanent unfalsifiable suppression, i.e. this issue again (§5, **S3**; mutant MS8).
- **The named blocker's status is checked, and the hatch itself expires.** If the blocker
  is `:done` or `:cancelled`, the deferral is stale again. This is the whole point: the
  hatch is not an exemption, it is a *machine-checkable assertion that goes stale on its
  own* (mutant MS9). Self-reference (`blocked-by:` naming the entry's own id) is
  rejected — it would be an unfalsifiable self-license.
- **Free text after it is still required**, so R3's spirit (a human-readable reason)
  survives the hatch rather than being replaced by it.

**Rejected alternatives, named so nobody re-opens them silently:**

- *A free-text exemption* ("`-- deliberately deferred, see note`"): reintroduces the exact
  unfalsifiability this issue exists to remove. This is what R3 already is.
- *A date-based `expires: 2026-12-01` hatch*: a date is a promise about the future, not a
  fact about the world. It goes red for a reason unrelated to whether the deferral is
  still justified, which produces the permanently-red-gate failure D3-of-ISS-0231
  rejected, and it invites renewal-by-bumping-the-date.
- *An exception list in the module* (ids, wildcards, prefixes): §8 I5 forbids it outright.

### D7 — Companion doc edit to `TASK_QUEUE.md` (in scope)

`docs/agents/protocols/TASK_QUEUE.md` (around line 265) is where the deferral convention
is written, and it currently states the marker and rationale are mandatory without saying
anything about a deferral remaining justified. **In scope for this run**, following
ISS-0231's OQ-1 ruling verbatim in shape: without it, S1 hard-fails on a condition the
protocol never stated, which is a gate enforcing an undocumented rule. The edit states
(a) that a deferral goes stale once its stage becomes active, (b) the derivation in one
sentence, and (c) the `blocked-by: REQ-NNN` grammar. It registers nothing and changes no
`impl_order`.

---

## 5. Rules and exit contract

### Hard rules — any violation ⇒ non-zero exit

- **S1 — no deferred requirement is STALE.** A deferral is stale when its stage is
  `:active` (§3.3, self-excluded per §3.5) and it carries no *live* `blocked-by:` scope
  (§S3). The violation message names the entry's `REQ-NNN`, its line, its stage, and the
  specific sibling ids/statuses that made the stage active — so the reader can act
  without re-deriving anything.
- **S2 — every deferred requirement carries a `stage:`.** Absent stage ⇒ staleness is
  undecidable ⇒ violation (§3.6). Not a silent pass.
- **S3 — a `blocked-by:` scope resolves and is live.** Violated when the named id is not
  present in the corpus, when it is the entry's own id, or when the named requirement's
  status is `:done` or `:cancelled` (the hatch has expired — the deferral is stale, and
  the message says so in those words).
- **S4 — every requirement's status is a recognised value.** `:unknown` ⇒ violation,
  naming the entry and the offending raw token. This is the totality defence, transplanted
  from ISS-0231's R2: an unrecognised status must land in a *failing* bucket, because
  silently treating it as inactive would let a typo (`status: donee`) un-activate a stage
  and make a stale deferral look legitimate. Applied to **all** entries, not just deferred
  ones (OQ-2). Measured today: 0 of 115 are `:unknown`, so this is vacuously green.
- **S5 — the corpus is non-empty and shaped.** `entry_count > 0` and at least one entry
  yields a recognised status. A scan finding nothing is never a silent green pass. This
  duplicates part of the registration check's R5 deliberately: the new module must be a
  correct pure function on its own, not correct only because another task ran first.

### Always printed, never gating

- The **stage-activity table** (§3.4's shape): each stage, its status histogram, and the
  derived `:active`/`:inactive` — so the derivation is visible and auditable rather than
  hidden inside an exit code. This block never gates.
- The **deferral roster**: every deferred entry with its stage, scope
  (`stage-scoped` | `blocked-by: REQ-NNN`), verdict, and the one-line reason for that
  verdict. Legitimate deferrals are printed and stay green — that is ISS-0231's D3
  principle preserved. **Only the `:stale` subset gates.** This is the precise, narrow
  change to what "deferred" costs you: documented-and-still-true stays free, exactly as
  before; documented-but-no-longer-true now fails.

On today's corpus both blocks render with an empty roster and the §3.4 table, exit 0.

### Exit contract

Exits `0` iff S1–S5 all hold; `Mix.raise/1` otherwise, naming every violating entry by
exact `REQ-NNN` and rule id, in the shape `format_violation/1` already establishes:
`[S1] REQ-118 (line 5602): ...`.

---

## 6. Module and function shapes

### 6.1 Types

```
@type status :: :pending | :in_progress | :done | :blocked | :cancelled | :unknown
@type activity :: :active | :inactive
@type scope :: :stage_scoped | {:blocked_by, String.t()}
@type verdict :: :legitimate | :stale | :undecidable

@type deferral :: %{
        id: String.t(),                 # "REQ-118"
        line: pos_integer(),            # 1-based line of the `- id:` line
        stage: String.t() | nil,        # nil ⇒ :undecidable, S2
        status: status(),               # the deferred entry's own status
        scope: scope(),                 # parsed from the rationale, §D6
        rationale: String.t() | nil,    # carried through from the registration entry
        verdict: verdict(),
        reason: String.t()              # human-readable justification for the verdict
      }

@type stage_facts :: %{
        stage: String.t(),
        counts: %{status() => non_neg_integer()},
        activity: activity(),
        witnesses: [String.t()]         # ids whose status conferred activity; [] if inactive
      }

@type violation :: %{
        rule: String.t(),               # "S1".."S5"
        id: String.t() | nil,           # REQ-NNN, or nil for the file-level rule S5
        line: pos_integer() | nil,
        message: String.t()
      }

@type audit :: %{
        deferrals: [deferral()],
        stages: [stage_facts()],        # sorted by stage id
        statuses: %{String.t() => status()},   # every REQ-NNN → its normalised status
        deferral_count: non_neg_integer(),
        stale_count: non_neg_integer(),
        violations: [violation()]
      }
```

### 6.2 Public functions

```
@spec audit(content :: String.t()) :: audit()
```

Pure, and the whole point of the design. Takes **content, not a path**, so hermetic
fixture strings go straight in (§1.1's consequence; D1). Internally calls
`Mix.Tasks.Letflow.CheckRequirementsRegistration.scan/1` on the same content, reads
`:stage`, `:state`, `:rationale`, and the newly-added `:status` off the returned entries,
derives stage activity, classifies every `:deferred` entry, and collects S1–S5. Never
raises on content — a malformed corpus is expressed as violations in the returned audit.
Raises only on a non-binary argument.

Deliberately **not** named `scan/1`: a test file that exercises both modules would
otherwise hold two same-named public functions with different return shapes.

```
@spec stage_activity(entries :: [map()]) :: [stage_facts()]
```

Pure. The §3.3 ruling, isolated so mutants MS1/MS2/MS3 have a single target and one test
group can pin the whole activity table. Takes the registration module's entry list.

```
@spec classify_deferral(deferral_entry :: map(), [stage_facts()], statuses :: %{String.t() => status()}) :: deferral()
```

Pure, single-entry — the analogue of `classify_entry/1`, and the unit the fixture tests
and most mutants target. Returns exactly one `verdict` per call, with `reason` populated
in every branch (including `:legitimate`, so a green roster still explains itself). Applies
self-exclusion (§3.5) against the `stage_facts` witnesses.

```
@spec parse_scope(rationale :: String.t() | nil) :: scope()
```

Pure. The §D6 grammar, anchored. Returns `:stage_scoped` for anything that is not a
well-formed anchored hatch — including a malformed near-miss, which must **not** silently
become a hatch.

```
@spec normalise_status(raw :: String.t() | nil) :: status()
```

Pure, total. First whitespace-delimited token only (§6.3 trap MS4). Anything outside the
declared set, and `nil`, map to `:unknown` — never to a default that happens to pass.

```
@spec render(audit()) :: iodata()
```

Pure. The §5 always-printed blocks plus the violation list, split out so a test can assert
on the roster and the activity table without capturing task IO.

```
@spec run(args :: [String.t()]) :: :ok      # @impl Mix.Task
```

Reads `docs/requirements.yaml` (path in a module attribute), calls `audit/1`, writes
`render/1` to stdout, then `Mix.raise/1` iff `violations != []`. Accepts and ignores Mix's
arg list, matching the sibling tasks' shape.

### 6.3 The status-extraction trap (measured, and the reason D4's addition is specified precisely)

Measured in §1.1: **8 of the 115 `status:` lines carry a trailing comment**, e.g.

```
    status: cancelled  # MVP-1 milestone dropped, see REQ-101's note
```

An extractor that captures rest-of-line (`~r/^\s+status:\s*(.*)$/`) yields
`"cancelled  # MVP-1 milestone dropped, see REQ-101's note"`, which matches no declared
status, so **S4 would fire on 8 real entries and the gate would be red on day one for a
non-reason** — precisely the failure D3-of-ISS-0231 argues destroys a gate's credibility.
The extractor must take the **first whitespace-delimited token** (`~r/^\s+status:\s*(\S+)/`),
mirroring the existing `@stage_re`, which already has this shape and is therefore the
template to copy rather than reinvent.

Second half of the same trap: status lines must be read from **attributed** lines only
(the existing ≥4-space `@attributed_re` filter), never from any line following the entry.
Measured: all 115 sit at exactly 4 spaces and 0 sit deeper, but the corpus contains
2-space prose block notes between entries, and the registration module's own history shows
that dropping the indentation rule sweeps them in.

### 6.4 Files touched

| file | change |
|---|---|
| `lib/mix/tasks/letflow.check_deferral_staleness.ex` | **new** — the module above |
| `lib/mix/tasks/letflow.check_requirements_registration.ex` | the single bounded addition of D4: `status` key + `@status_re` + private extractor + one `@type` line. Nothing else. |
| `mix.exs` | `letflow.check` alias gains one entry at position 3 (D5) |
| `docs/agents/protocols/TASK_QUEUE.md` | the deferral-convention paragraph gains the staleness rule and the `blocked-by:` grammar (D7) |
| `docs/issues/ISS-0258.yaml` | the issue record — does not exist yet in this worktree (verified); created by the run |
| `test/mix/tasks/letflow_check_deferral_staleness_test.exs` | **new** — §7, written by TEST-DESIGNER at Step 4, not by ELIXIR-DEV |

**Nothing else.** In particular: no edit to `docs/requirements.yaml`'s data of any kind,
no `impl_order` or `status` value added, removed, or altered anywhere, and no call to
`letflow-queue`.

### 6.5 Moduledoc hazard (must be handled at implementation time)

`docs/anti-patterns.md` line 1195, "A grep-shaped acceptance criterion can be tripped by
the module's own moduledoc describing the invariant." This module's moduledoc will want to
quote the marker form and the hatch grammar, so the new `.ex` file will itself contain the
literal strings `# impl_order: UNREGISTERED` and `blocked-by: REQ-NNN`. Consequences:

- The check scans `docs/requirements.yaml` **only** — never `lib/`, never a directory walk.
  Keep it that way; the module would otherwise fail its own check, exactly as ISS-0231's
  moduledoc would have.
- Any acceptance criterion for this fix phrased as a repo-wide `grep` for either form will
  hit the new module and its test file. Scope such criteria to `docs/requirements.yaml`,
  or expect and account for the extra hits.

---

## 7. Regression-test story (WF-03 Step 4)

### 7.1 Fail-first must be mutation-based

This fix **adds** a module, so the pre-fix failure is `UndefinedFunctionError` for every
test in the file, which proves only that the module is new. WF-03's clause *"when the
pre-fix failure is 'the code under test does not exist'"* applies in full: fail-first is
satisfied **only** by mutating the shipped logic and recording which tests fail per
mutant, and TEST-DESIGN-VALIDATOR must independently apply at least one mutant and run it.

Isolation technique to copy from `WF03-ISS0106-20260821` and `WF03-ISS0231-20260822`:
apply mutants in a throwaway `git worktree`; if applied in place, revert with
`git checkout --` and verify (`git status --porcelain lib/ test/` empty **and** the test
file re-runs green) before completing the handoff.

### 7.2 The live corpus has ZERO signal for the staleness half — load-bearing

Measured (§1.1): the deferred set is empty, 0 markers of 115 entries. So **every
live-corpus test of S1/S2/S3 passes vacuously and would keep passing under almost every
mutant in §7.3.** This is the same trap ISS-0231 documented in its own §7.2 and then hit
for real when PR #495 emptied the bucket mid-run. Consequences that are requirements, not
suggestions:

- The hermetic fixture group is the *entire* regression value for S1/S2/S3, and D1's
  public content-in core is what makes it possible.
- **No mutant in §7.3 may cite a live-corpus test as its only detector**, except MS1,
  MS2, MS4 and MS5, where the live corpus genuinely discriminates (noted per row).
- A test asserting "the live file is green" is a *guard against over-firing*, not evidence
  the rule works. Both kinds are needed; they must not be confused for each other.

### 7.3 Named mutant traps

Each names the trap it targets and the tests that must fail under it. A mutant no test
detects is a coverage hole to close before Step 4 passes.

| # | mutant | what it reproduces | must be caught by |
|---|---|---|---|
| **MS1** | Add `:cancelled` to `@active_statuses`. | The refuted rule of §3.3 — S8 (1 cancelled) becomes active and **all 21 historical deferrals flag stale**. | F-CANCELLED-NOT-ACTIVE, F-S8-SHAPE-LEGIT |
| **MS2** | Add `:pending` to `@active_statuses`. | Every stage with any requirement is active ⇒ every deferral ever written is stale ⇒ the permanently-red gate D3-of-ISS-0231 rejects. | F-PENDING-NOT-ACTIVE, F-S8-SHAPE-LEGIT, T-LIVE-ACTIVITY |
| **MS3** | **Remove `:done` from `@active_statuses`.** | **ISS-0258 reproduced inside its own fix** — nothing is ever active, so no deferral is ever stale and the gate is green forever. **The mandatory mutant**; the analogue of ISS-0231's M1. | F-DONE-IS-ACTIVE, F-STALE-BASIC, T-LIVE-ACTIVITY |
| **MS4** | Extract `status` as rest-of-line instead of first token (§6.3). | The 8 real `cancelled  # ...` entries become `:unknown` ⇒ S4 fires ⇒ red on day one for a non-reason. | F-STATUS-TRAILING-COMMENT, T-LIVE-GREEN, T-LIVE-STATUS-TOTAL |
| **MS5** | Read `status:` from unattributed lines (drop the ≥4-space rule). | A 2-space prose block-note `status:` swept into an entry. | F-STATUS-BLOCK-NOTE, T-LIVE-STATUS-TOTAL |
| **MS6** | Map an unrecognised status to `:pending` (or drop S4) instead of `:unknown`-and-fail. | Silent absorption — a typo'd `status: donee` un-activates a stage and a stale deferral looks legitimate. The ISS-0231 `:unclassified` defence removed. | F-UNKNOWN-STATUS-FAILS, F-TYPO-DOES-NOT-DEACTIVATE |
| **MS7** | Match `blocked-by:` anywhere in the rationale instead of anchored at its start. | ISS-0231's M8 absorption bug in this issue's clothes — prose mentioning the form suppresses a real staleness. | F-HATCH-ANCHOR |
| **MS8** | Accept `blocked-by:` without checking the named id exists. | A dangling `REQ-999` becomes a permanent unfalsifiable suppression — ISS-0258 recreated inside the hatch. | F-HATCH-DANGLING |
| **MS9** | **Accept `blocked-by:` regardless of the blocker's status.** | The hatch never expires — the exact "green forever" property this issue exists to remove, in the one place it was reintroduced deliberately. **Second mandatory mutant.** | F-HATCH-BLOCKER-DONE, F-HATCH-BLOCKER-CANCELLED |
| **MS10** | Drop self-exclusion (§3.5) from the activity fold. | A deferred-and-`done` entry activates its own stage and flags itself — an unfixable red. | F-SELF-EXCLUSION |
| **MS11** | Demote S1 from the violation list to a printed advisory (keep the roster). | The whole gate becomes a report nobody's exit code depends on — ISS-0258's own root cause, one level up again. | F-STALE-EXITS |
| **MS12** | Treat a deferred entry with no `stage:` as legitimate instead of S2. | A silent exemption reachable by deleting one field. | F-DEFERRED-NO-STAGE |
| **MS13** | Compare stage ids by prefix/`String.starts_with?` rather than exact equality. | `S1` matching `S10`; activity leaking between stages. | F-STAGE-EXACT-MATCH |

### 7.4 Test inventory (specs, for TEST-DESIGNER to build from)

**Hermetic fixture tests** — strings through `audit/1` / `classify_deferral/3` /
`stage_activity/1` / `parse_scope/1` / `normalise_status/1`. No file IO. Every fixture is a
minimal corpus with a `requirements:` key and enough entries to make the point.

- **F-STALE-BASIC** — a `:deferred` entry in a stage where a sibling is `done` ⇒ verdict
  `:stale`, an S1 violation naming that id, non-zero `stale_count`.
- **F-LEGIT-BASIC** — a `:deferred` entry in a stage whose only siblings are `pending`
  ⇒ `:legitimate`, zero violations.
- **F-S8-SHAPE-LEGIT** — a fixture reproducing the real S8 shape (10 `pending`, 1
  `cancelled`, one entry deferred with `-- see the S8 note above`) ⇒ `:legitimate`. This is
  the "must not be wrong about the 21 known-good cases" test.
- **F-DONE-IS-ACTIVE / F-PENDING-NOT-ACTIVE / F-CANCELLED-NOT-ACTIVE / F-BLOCKED-IS-ACTIVE
  / F-IN-PROGRESS-IS-ACTIVE** — one per status, asserting `stage_activity/1`'s derived
  `activity` directly. These pin §3.3's ruling value by value.
- **F-EMPTY-STAGE-INACTIVE** — a stage with zero requirements is `:inactive` and produces
  no violation (the S5/S6/S7 case, by rule not exception).
- **F-SELF-EXCLUSION** — a stage whose *only* non-`pending` requirement is the deferred
  entry itself ⇒ `:legitimate`, not self-flagged.
- **F-STATUS-TRAILING-COMMENT** — `status: cancelled  # MVP-1 milestone dropped, see
  REQ-101's note` ⇒ `:cancelled`, **not** `:unknown`. Copied verbatim from the real file.
- **F-STATUS-BLOCK-NOTE** — a 2-space prose line containing `status:` between two entries;
  both entries still resolve their own status and neither gains a second one.
- **F-UNKNOWN-STATUS-FAILS** — `status: donee` ⇒ `:unknown` **and** an S4 violation naming
  the entry and the raw token.
- **F-TYPO-DOES-NOT-DEACTIVATE** — a stage whose only `done` sibling is typo'd to `donee`:
  the run is red (S4), never a quiet green where the deferral reads legitimate.
- **F-NO-STATUS-LINE** — an entry with no `status:` at all ⇒ `:unknown` ⇒ S4.
- **F-HATCH-BASIC** — `-- blocked-by: REQ-042 -- waiting on the token kernel`, blocker
  `pending`, in an active stage ⇒ `:legitimate`, scope `{:blocked_by, "REQ-042"}`.
- **F-HATCH-BLOCKER-DONE** — same, blocker `done` ⇒ `:stale`, S1/S3 violation whose message
  says the hatch expired.
- **F-HATCH-BLOCKER-CANCELLED** — same, blocker `cancelled` ⇒ `:stale`.
- **F-HATCH-DANGLING** — `blocked-by: REQ-999` (absent from the corpus) ⇒ S3 violation, and
  **not** treated as a valid hatch.
- **F-HATCH-SELF** — `blocked-by:` naming the entry's own id ⇒ S3 violation.
- **F-HATCH-ANCHOR** — a rationale whose *middle* contains `blocked-by: REQ-042`, e.g.
  `-- unlike the blocked-by: REQ-042 cases, this one waits on S8` ⇒ scope `:stage_scoped`,
  hatch **not** activated, and the entry judged on stage activity alone.
- **F-HATCH-MALFORMED** — `blocked-by: REQ_042`, `blocked-by:` with no id, `blockedby:
  REQ-042` ⇒ `:stage_scoped`, never a silent hatch.
- **F-HATCH-NO-RATIONALE** — `blocked-by: REQ-042` with no trailing free text ⇒ rejected as
  a hatch (D6's fourth property), so R3's spirit survives.
- **F-DEFERRED-NO-STAGE** — a deferred entry with no `stage:` ⇒ verdict `:undecidable` and
  an S2 violation, never a pass.
- **F-STAGE-EXACT-MATCH** — a fixture with stages `S1` and `S10`; a `done` requirement in
  `S10` must not activate `S1`.
- **F-STALE-EXITS** — a corpus with one stale deferral produces an S1 *violation* (the
  exit-code-bearing list), not merely a printed roster line.
- **F-ROSTER-EXPLAINS** — `render/1` on a stale fixture names the id, its stage, and at
  least one witness id whose status made the stage active; on a legitimate fixture it
  prints the entry with a `:legitimate` reason and no violation block.
- **F-NO-REQUIREMENTS-KEY** — content with no `requirements:` key ⇒ a violation, and **not**
  a silent zero-deferral green pass.
- **F-EMPTY-SECTION** — `requirements:` present, zero entries ⇒ S5 violation.

**Live-corpus tests** — against the real `docs/requirements.yaml`. Per §7.2 these are
over-firing guards plus genuine signal for the status-parsing and activity halves only.

- **T-LIVE-GREEN** — the real file produces zero violations, exit 0. Today this is
  vacuously true for S1–S3 and genuinely load-bearing for S4/S5.
- **T-LIVE-STATUS-TOTAL** — every one of the entries resolves to a status other than
  `:unknown`; `count(:unknown) == 0`. **Real signal**: catches MS4 and MS5.
- **T-LIVE-ACTIVITY** — the derived activity table is `active` for S0, S1, S2, S3, S4 and
  `inactive` for S8, S9. **Real signal**: catches MS1, MS2, MS3. Deliberately asserts the
  *set*, not the counts, since the counts change legitimately with every merge. See OQ-5:
  TEST-DESIGNER writes a note in the test file so a future failure reads as "expected
  update" rather than "regression".
- **T-LIVE-DEFERRED-COUNT-IS-ZERO** — asserted **with an explanatory comment**, not as a
  permanent invariant: it documents that today's green is vacuous for S1–S3, so a future
  reader who adds a deferral and sees this test change knows the staleness rule has just
  become load-bearing rather than assuming a regression.

**Task-level tests:**

- **T-TASK-RAISES** — `run/1` against a fixture content with a stale deferral raises
  `Mix.Error`.
- **T-TASK-PRINTS-ON-GREEN** — the activity table and roster are printed even when the run
  is green; the report is unconditional.

**Cross-module test:**

- **T-REG-STILL-GREEN** — `mix letflow.check_requirements_registration` remains green and
  its existing test file remains green after D4's `status` addition. The bounded change
  must be provably bounded.

---

## 8. Invariants

- **I1.** The new check **never writes** to `docs/requirements.yaml`, never assigns or
  suggests an `impl_order`, never edits a `status`, and makes no network call — in
  particular none to `letflow-queue`. It is a read-only auditor.
- **I2.** It scans `docs/requirements.yaml` **only** — never `lib/`, never a directory
  walk (§6.5).
- **I3.** Exactly **one** parser exists for this file across both tasks:
  `CheckRequirementsRegistration.scan/1` (D4).
- **I4.** `:legitimate` deferrals **never** influence the exit code, at any count. Only
  `:stale` and `:undecidable` gate. The visible-debt principle survives; only its
  never-expiring half changes.
- **I5.** **No exception list of any kind** — no grandfathering, no wildcard, no id
  allowlist, no prefix suppression. The `blocked-by:` hatch is not an exception list: it
  is a machine-checkable assertion that expires on its own (D6).
- **I6.** The gate is green on `main` at the moment it lands — measured, vacuously so, on
  a corpus with 0 deferrals and 0 unknown statuses — so **any future red is a new fact**.
- **I7.** `normalise_status/1` is total, and its non-member branch is `:unknown`, which
  **hard-fails**. There is no branch anywhere that treats an unrecognised status as
  acceptable.
- **I8.** D4's change to `CheckRequirementsRegistration` touches no `:deferred` code path,
  no rule R1–R6, and not the exit-code contract.

---

## 9. Open questions — ruled, not guessed

Each is **ruled** below so ELIXIR-DEV is never left inferring; each is *flagged* because a
later gate may legitimately reverse it, and I would rather it be reversed loudly than
discovered as an unstated assumption mid-build.

- **OQ-1 (the one ruling against Step 1's recommendation).** Does `:blocked` confer stage
  activity? **RULED: yes** (§3.3), on the asymmetric-cost argument. Step 1 recommended
  `{done, in_progress}`. Measured impact of the difference **today: zero** — no requirement
  anywhere is `blocked`. Reversal is one token in `@active_statuses` plus flipping
  F-BLOCKED-IS-ACTIVE. **REVIEWER should confirm or reverse explicitly at the Step-3 gate.**
- **OQ-2 (blast radius of S4).** Should the unknown-status rule apply to all 115 entries or
  only to entries whose status feeds a deferral's stage? **RULED: all entries.** An
  unrecognised status is a corpus defect regardless of who reads it, the scoped version is
  harder to reason about, and it is vacuously green today (0 of 115 unknown, measured).
  Flagged because it widens the gate beyond deferrals — the only place this design touches
  a requirement that is not deferred.
- **OQ-3 (a real inconsistency I found, needs a one-word doc fix).**
  `docs/requirements.yaml` line 8 declares `Status values: pending | in_progress | done |
  blocked`. **`cancelled` is used 8 times and is not declared there.** S4 will accept
  `cancelled` as a known status, which means the module's known-status set would diverge
  from the file's own documented set. **RULED: amend the header to declare `cancelled`, in
  scope for this run** — one word, no data change — because otherwise the gate encodes a
  value the file's own legend denies, and a future reader tightening the legend would
  silently make 8 entries `:unknown`. If REVIEWER prefers this as a separate doc issue, S4's
  known set is unaffected either way; only the doc edit moves.
- **OQ-4 (alias slot).** Position 3 is recommended and justified (D5), but alias ordering is
  decision-record territory (0005, which legislates slot 1 only). Following ISS-0231's OQ-2
  precedent, the design is indifferent to the exact index and firm only about being in the
  alias at all. Say so at the Step-3 gate if another slot is preferred.
- **OQ-5 (future staleness of T-LIVE-ACTIVITY).** That test pins the active set
  `{S0..S4}`. It will change legitimately when S5/S6/S7 are expanded, or when S8 starts.
  TEST-DESIGNER writes that note into the test file itself so a future failure reads as
  "expected update", not "regression". This is the same hazard ISS-0231's OQ-5 recorded for
  T-ROSTER, and it landed for real one run later — so it is a near-certainty here, not a
  hypothetical.
- **OQ-6 (deliberately out of scope).** Nothing in this design detects a *stale-by-time*
  deferral in an inactive stage — a deferral pending S8 stays legitimate for as long as S8
  stays unstarted, which could be months. That is intentional: it is a true statement about
  the world, and a calendar-based rule was considered and rejected (D6). The idle-pipeline
  risk it leaves open is *stage-level*, not deferral-level, and belongs to a different
  detector (something watching whether any stage is progressing at all). **Not fixed here;
  ORCH to `register_task` if wanted** — recorded rather than dropped, in the same shape
  ISS-0231's follow-up recorded this very issue.

---

## 10. Traceability

| ISS-0258 concern | where it is answered |
|---|---|
| `DEFERRED` is green forever, with no expiry | §1, §5 S1 |
| Distinguish stage-become-active from legitimately-pending-a-stage | §3.3 ruling, §3.4 applied to the live corpus, §6.2 `classify_deferral/3` |
| "Active" is not a readable field | §3.1, derived in §3.3, printed in §5 so the derivation is auditable |
| Does `blocked` count? Does `cancelled`? | §3.3 (yes / no, each with its reason); OQ-1 flags the first |
| The sibling-requirement false-positive class | §D6 — anchored `blocked-by: REQ-NNN`, machine-checkable, self-expiring |
| Why a separate detector | §D3 — three reasons verified plus two of my own |
| Reuse vs. re-parse | §D4 — reuse, with the `status` addition named as a bounded change |
| Wired into a gate a human/CI will see | §D5 — slot 3 of `letflow.check`; no CI config exists anywhere, verified |
| No grandfather clause, no exception list | §1.1 measurement (0 deferrals), §8 I5, I6 |
| Testability against a zero-signal live corpus | §D1 (public content-in core), §7.2, §7.3 (13 traps), §7.4 |
| The moduledoc self-check hazard | §6.5 |
| The module-name collision class | §D2 |
