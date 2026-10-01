# CODE-DESIGN-VALIDATOR verdict — ADHOC-20261001-001 (drain-mode scope-creep guardrail design)

**Verdict: PASS**

Independently re-read `requirement-drain-mode.md` (full), `req-validator-verdict.md`
(full), and `design-drain-mode.md` (full), then re-read every live anchor file at HEAD
(`a59a93a6`) directly — `docs/agents/ORCHESTRATOR.md` §4a/§5/§9/§10,
`docs/agents/instructions/core-directives.md` lines 65-89, `docs/agents/protocols/
TASK_QUEUE.md` lines 440-478, `docs/agents/AGENT_SYSTEM.md` §9, and both ADR precedents
(0004, 0017) in full — rather than trusting CODE-DESIGNER's own claimed mapping or
anchor quotes. Every quoted "existing text" block in the design matches the live file
byte-for-byte at the lines CODE-DESIGNER cites.

---

## 1. AC → design element mapping (built independently, not from CODE-DESIGNER's table)

| AC | Requirement text (summary) | Design element | Verdict |
|---|---|---|---|
| 1 | §4a MUST forbid self-authored governance edits under drain license | File 1, new "MUST NOT" paragraph, naming the exact `AGENT_SYSTEM.md` §9 surface list | covered |
| 2 | Discovering a gap mid-drain MUST be filed, not authored inline | File 1, "The correct behavior: file it, don't write it" paragraph | covered |
| 3 | Extend "drifting into unrelated work" sentence to name governance self-edits | File 1, appended sentence directly after the existing paragraph | covered |
| 4 | core-directives.md bullet MUST carry the guardrail in summary + cross-ref | File 3, appended sentences to the existing bullet | covered |
| 5 (REQ-VALIDATOR's rewrite) | §10 MUST gain one present-tense, checkable sentence on multi-governance-file + no-citation | File 2, new checklist item 7 | covered, matches rewrite verbatim in substance |
| 6 | Trigger list MUST remain intact | Untouched — confirmed by diff against live §4a text | covered |
| 7 | Stop-condition list MUST be preserved, item 4 layered not replaced | File 1c replaces only item 4's own text with an operational test; items 1–3 untouched | covered |
| 8 | Operational two-part interrupt test, explicit carve-outs, multi-host out of scope | File 1c new text | covered |
| 9 | TASK_QUEUE.md MUST forbid multi-task pre-claiming | File 4, new paragraph's MUST NOT sentence | covered |
| 10 (SHOULD) | TASK_QUEUE.md SHOULD cross-reference §4a | File 4, opening sentence of new paragraph | covered |
| 11 | §5 escalation record MUST state mid-drain + pending count | File 5, new item 5 on the escalation-record list | covered |
| 12 | §9 logging MUST mark drain-continued dispatches | File 5 continued, new §9 paragraph | covered |
| 13 | REQ-VALIDATOR MUST independently re-derive the AGENT_SYSTEM.md "no-change" finding | Not a design artefact (correctly) — already discharged by `req-validator-verdict.md` §5; design adds a third independent confirmation rather than fabricating an edit to satisfy a checklist | covered, correctly not forced into an edit |

No AC is unmapped, and no design section exists that doesn't trace back to a specific
AC. I did not accept CODE-DESIGNER's own "AC mapping" tables at face value — I rebuilt
the above from the requirement text and the live files independently; they agree.

## 2. No implementation already performed; no implementation code

`git status --porcelain` shows only `.vite/` (unrelated, pre-existing) and
`handoffs/ADHOC-20261001-001/` (this run's own handoff artefacts) as untracked.
`git diff --stat` against `docs/agents/ORCHESTRATOR.md`, `core-directives.md`,
`TASK_QUEUE.md`, and the prospective `0041-*.md` ADR path returns empty — none of the
four governance files has been touched. The design itself only ever uses
`INSERT AFTER`/`REPLACE` instructions addressed to a future implementation step and
never claims a file was already edited. All content is prose/markdown text for a
docs-only change — no `.ex`/`.exs` bodies, no code. Pass.

## 3. Is the scope-creep guardrail text actually unambiguous?

Stress-tested with adversarial readings:

- **"The user told me it's fine" cover story** — explicitly foreclosed: the MUST-NOT
  paragraph lists "the user would obviously want this," "it's a small/narrow/docs-only
  change" as named non-exemptions, and is independent of §10's file-count checklist (a
  single-file governance self-edit mid-drain is still forbidden by this prose, not left
  to depend on hitting ">1 file").
- **"I'm not technically in drain mode, I was told to fix one specific thing, so I'll
  also tweak a second governance file while I'm here"** — the exact PR #2081 shape. This
  is independently closed by File 2's new §10 item 7, which is *not* scoped to drain
  mode at all ("a change touching more than one canonical governance/process surface...
  with no cited requirement/decision record automatically fails check 1"), so it closes
  the loophole project-wide, not only inside drain-mode sessions. This is a reasonable
  and deliberate strengthening beyond the narrowest reading of the AC.
- **Residual, out-of-scope gap (noted, not a revision requirement):** a genuinely
  *single*-file self-authored governance edit, outside drain mode, still passes §10's
  original six checks (it's docs, not code) unless caught by the new §4a prose — and
  §4a's prose is itself scoped to drain-mode conduct ("as a side effect of draining the
  backlog"). A single-file governance self-edit made entirely outside drain mode is not
  closed by anything this requirement adds. This is a legitimate observation but outside
  this requirement's explicitly scoped incident (PR #2081 was two files, under drain-mode
  framing) — flagging for a possible future issue, not a blocking gap in this design.

Verdict: the guardrail text is unambiguous and enforceable for the incident class this
requirement targets. Pass, with the above noted as a follow-up worth filing (not a
revision to this design).

## 4. Is the operational interrupt test actually checkable?

Yes. The two-part test — (a) arrives on the session's own primary user-facing input
channel, (b) not authored by this same session's own prior turn — gives a mechanical
check rather than a judgment call, and explicitly enumerates the two things that would
otherwise be read into "a real human turn": ORCH's own status updates (excluded by (b))
and another session's activity via §7.1/`TASK_QUEUE.md` (excluded by name, deferred to
those sections' own locking). This directly satisfies AC 8, including the
multi-host-out-of-scope clause. Pass.

## 5. ADR 0041 structural match against 0004/0017

Read both precedents in full. 0004's shape: title/Status+Owner → `## Question` →
`## Decision` → `## Reasoning` → `## Consequences` (+ later dated addenda). 0017's
shape: title/Status+Owner → `## Question` → `## Evidence` → `## Decision` →
`## Consequences` → `## What this record does not decide`.

The drafted 0041 uses: title/Status+Owner → `## Question` (two sub-questions) →
`## Decision` (A/B/C) → `## Reasoning` → `## Consequences` → `## What this record does
not decide`. This is a correct hybrid of both precedents' section sets, and the design
explicitly justifies omitting a separate `## Evidence` section (the incident itself is
the evidence, same as 0004's own shape, which also has no Evidence section). No
structural mismatch found. Pass.

## 6. Does anything weaken an existing gate?

Cross-checked against live §5, §7/§7.1, §8, §10:

- **§5** — new item 5 is additive to the existing 4-item "On `rework_count >= max_rework`"
  list; nothing removed or loosened.
- **§7/§7.1 (locking)** — untouched by this design; File 1c's interrupt test explicitly
  defers multi-session/multi-host scenarios to §7/`TASK_QUEUE.md`'s own locking rather
  than overriding it — consistent, not contradictory.
- **§8 (stage gates)** — untouched, no interaction claimed.
- **§10 (sizing)** — new item 7 is appended to the existing 6-item checklist in the same
  "any single 'no' means full workflow" style; it adds a new way to fail the checklist,
  never a new way to pass it. Strictly additive.

No existing gate is weakened anywhere in this design. Pass.

---

## Minor note (not a revision requirement)

`requirement-drain-mode.md`'s header still reads "Status: drafted, awaiting
REQ-VALIDATOR," which is stale — `req-validator-verdict.md` already resolved this to
PASS-WITH-REVISIONS and the body already reflects the AC-5 rewrite and file #6 addition
the verdict asked for. This is a bookkeeping staleness in the requirement file's own
header, not a design defect; flagging for DOC-UPDATER/whoever closes this run to fix
when the header is next touched, not blocking this gate.

---

## Summary

All six checks pass. Design is complete against every acceptance criterion, contains no
already-performed edits and no implementation code, the guardrail language is
unambiguous for the incident it targets (with one out-of-scope residual gap flagged as a
follow-up, not a revision), the interrupt test is mechanically checkable, the new ADR
matches house format, and nothing proposed weakens an existing gate. Cleared to
implementation.
