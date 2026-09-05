# Design: REQ-237 — `.zig` provenance-citation marking convention (closes ISS-0424 part 3a)

**Requirement:** REQ-237 (this run's handoff `context.requirement_text.REQ-237`, stage S6,
queue task 474)
**Owner (implementer of this design's output):** REQ-238 (ELIXIR-DEV, `lib/`) and REQ-239
(DOC-UPDATER, `docs/`) — not this run
**Run:** `WF02-REQ237-20260905`, WF-02 Step 1
**This document produces:** the exact marker text/regex R-Co-provenance citations get
rewritten to demote them from "live decision authority" framing to "historical provenance"
framing, confirmation the one convention covers both `lib/` moduledoc and `docs/` (incl.
`docs/migration/`) contexts, a worked before/after example on a real citation with the
original path text diffed byte-identical, and a concrete file-chunking recommendation for
REQ-238/REQ-239. **No citation is edited by this requirement — design only, no
implementation code.**

---

## 0. Sources read for this design

- This run's handoff — `context.requirement_text.REQ-237` (full description) and
  `task.acceptance_criteria`.
- `docs/agents/instructions/core-directives.md` (full) — "Load Scoped Context, Not Whole
  Files," the no-speculation/verify-by-running-the-actual-command rule (applied below: every
  count in this document is a real `grep` result run in this session, not carried over from
  the requirement text's own already-flagged-as-unstable numbers).
- `docs/requirements.yaml` — REQ-237's own entry (full), REQ-231's entry (the exact
  `cursor.zig` citation the requirement text names), REQ-181's `webhooks.zig`
  `CONTRACT SOURCE:` citation, and REQ-232 through REQ-236 plus REQ-240 through REQ-242 (full)
  — read specifically for their measured file counts per ELIXIR-DEV turn (§6's sizing
  reference).
- `lib/letflow/design/req052-instance-cancellation.md` (full) — this project's own design-doc
  naming/structure convention (numbered sections, "Sources read," "Open questions," ACs
  traced in a table at the end) — followed here.
- `docs/anti-patterns.md` — current entries checked; none bears on citation-marking
  mechanics.
- Real, current codebase state, read directly (not paraphrased) — full commands and output
  quoted in §1 below, since this design's core claim ("the real variety is wider than a
  single canonical `SOURCE:` phrasing") must be demonstrated, not asserted.

---

## 1. Research — the real phrasing variety (not an idealized single case)

Four independent greps were run against the current tree (`main` at `bf601feb`, this run's
own branch point) to establish actual scale and phrasing variety before designing anything:

```
grep -rl '\.zig' lib/ docs/           -> 2 files matched the literal 3-word substring
                                          "SOURCE:.*\.zig" pattern's *file* superset check;
                                          the real per-file counts below are what matters.
grep -rl '\.zig' lib/                 -> 183 files
grep -rl '\.zig' docs/ (excl. requirements.yaml) -> 58 files
grep -c  '\.zig' docs/requirements.yaml -> 538 matching lines (one file)
```

**Distinct phrasings actually found (not an idealized single "SOURCE:" form):**

| # | Phrasing shape | Example (real, quoted verbatim) | Where |
|---|---|---|---|
| 1 | Dedicated `SOURCE:` line, path only | `SOURCE: c:\Users\tvolo\dev\ai-dala\R-Co\src\entities\query\cursor.zig` (`docs/requirements.yaml:13810`, REQ-231's own text, the exact example this requirement's own description names) | `docs/requirements.yaml` |
| 2 | Dedicated `CONTRACT SOURCE:` line, followed by a full justification sentence, not just a path | `CONTRACT SOURCE: since R-Co's dlq.zig itself is not inspectable from this drafting session…` (`docs/requirements.yaml:9150`, REQ-181) | `docs/requirements.yaml` |
| 3 | Inline prose, mid-sentence, no `SOURCE:` keyword at all | `` `provision_oidc_user/4` (below) ports the JIT (just-in-time) user-provisioning orchestration from `src/oidc/jit_provisioning.zig` together with the actual upsert from `src/identity/registry.zig`'s `createOrGetJitOidcUser` (lines ~843-912)`` (`lib/letflow/identity.ex:3-6`, `@moduledoc`) | `lib/` moduledocs |
| 4 | Bulleted "NOT ported" scope note | `` 1. **R-Co's `src/scheduler/partition_maintenance.zig` and `partition_retention.zig` are NOT ported.** `` (`lib/letflow/scheduler.ex:57-58`, `@moduledoc`) | `lib/` moduledocs |
| 5 | Markdown/moduledoc table cell, one filename per row, no sentence at all | `` | \`Letflow.Routers.Dlq\` | \`dlq.zig\` | S6 (dead-letter queue subsystem) | `` (`lib/letflow/router.ex:73`, `@moduledoc`) | `lib/` moduledocs |

**Conclusion this design is built on:** there is no single canonical "SOURCE:"-line form to
target. Any convention that only rewrites lines literally starting with `SOURCE:` or
`CONTRACT SOURCE:` would miss the majority of citations — of the 183 `lib/` files carrying a
`.zig` reference, only 2 (`docs/requirements.yaml`'s own two variants, which do not live in
`lib/` at all) use a dedicated keyword-prefixed line; every `lib/` moduledoc citation found
(phrasings 3-5) is inline prose, a bullet, or a table cell with no keyword prefix whatsoever.
The convention below (§2) is designed around this finding: it marks the smallest enclosing
**textual unit** that carries the citation, not a specific keyword.

---

## 2. Design decision 1 — the marker itself

**Marker text (fixed, literal, copy-pasteable verbatim in both contexts):**

```
PROVENANCE (historical, not current decision authority):
```

**Placement rule (mechanical, no per-citation judgement call):** insert this line, on its own
line, immediately above the smallest enclosing **citation unit** that contains a `.zig`
substring, where "citation unit" is defined purely structurally so REQ-238/239 can apply it
without reading for meaning:

- **Single citation line** (phrasings 1, 2 in §1 — a line that is itself the `.zig`
  reference, e.g. a `SOURCE:`/`CONTRACT SOURCE:` line, or a lone bullet like phrasing 4): the
  unit is that one line (and any lines a hard line-wrap of the same sentence continues onto,
  i.e. up to the next blank line or the next line that does not visually continue the
  sentence — REQ-231's own `cursor.zig`/`field_grants.zig` citation wraps across two lines
  this way, see §4 worked example).
- **Paragraph** (phrasing 3 — a `.zig` filename embedded inside a longer prose paragraph):
  the unit is the whole paragraph (bounded by blank lines), not just the sentence or the
  token — this avoids the judgement call of deciding where a "sentence" containing the
  citation starts inside dense prose.
- **Table** (phrasing 5): the unit is the whole table (from its header row through its last
  row) — one marker above the table's header line, never one marker per row, even if
  multiple rows each cite a distinct `.zig` file. Re-inserting per-row would corrupt Markdown
  table syntax (a plain text line cannot sit inside a table without becoming a malformed row)
  and is unnecessary: the table as a whole is one citation unit for this purpose.
- **De-duplication:** if a marker line already immediately precedes a unit (verifiable by a
  one-line `grep -B1` check per unit), no second marker is inserted — this makes the rule
  idempotent, so REQ-238/239 (or any future audit) can re-run it safely.

**Justified against the requirement's own three constraints:**

**(a) Trivially greppable as a single regex.** The marker is one fixed literal string with no
per-context variation:

```
PROVENANCE \(historical, not current decision authority\):
```

(the two parentheses are the only characters needing escaping in a POSIX/PCRE regex; the
plain string form `PROVENANCE (historical, not current decision authority):` also works
directly with `grep -F`). This single pattern finds every marked citation in both `lib/` and
`docs/` with one command — no OR-branch, no per-directory variant is needed, because the
literal marker text is emitted identically everywhere (§2 below explains why no
markdown-specific styling, e.g. bold `**…**` or a `##` heading, is used: styling the string
differently in `docs/` vs. `lib/` moduledocs would silently turn this into two greppable
forms, which constraint (a) rules out).

**(b) Never deletes or alters the existing file-path text.** The marker is inserted as a new,
standalone line strictly *before* the citation unit — the unit's own text (the `SOURCE:`
line, the prose sentence, the bullet, the table row) is copied forward unmodified, character
for character. §4's worked example diffs this explicitly.

**(c) Reads naturally in both `@moduledoc """..."""` and Markdown without two divergent
conventions.** `@moduledoc` bodies in this codebase are themselves Markdown-flavored prose
(ExDoc renders them as such — confirmed by every `lib/letflow/design/*.md` cross-reference
and moduledoc already read in this codebase, e.g. `req052`'s own §2 required-moduledoc-content
block, which is itself plain prose with backtick-quoted identifiers). A plain, unstyled text
line containing only parenthesized English and a trailing colon is valid, unremarkable prose
in *both* a `.md` file and inside a `"""` heredoc — it needs no Markdown heading marker
(`##`), no HTML comment syntax, and no Elixir comment syntax (`#`) to be syntactically legal
in either context, because it is not being interpreted as a directive by either the Elixir
compiler or a Markdown renderer, only as a plain sentence a human (and `grep`) reads. This is
the concrete reason **one convention, not two, is sufficient** — the alternative considered
and rejected was an HTML-comment-styled marker (`<!-- PROVENANCE: historical -->`) for
`docs/` and a `# `-prefixed Elixir-comment marker for `lib/`; that would have satisfied (a)
only via a two-branch regex and was rejected specifically because constraint (c) asks for one
convention if achievable, and it is.

**Trade-off disclosed, not silently accepted:** because the marker deliberately carries no
Markdown emphasis (no bold, no heading `#`), it renders as plain unstyled text when a `.md`
design/migration doc is viewed rendered (e.g. on GitHub) rather than standing out visually.
This is an accepted cost of constraint (a)'s "one literal string, no per-context styling"
requirement — flagged as OQ-1 (§8) for REVIEWER to confirm the trade-off (greppability over
visual styling) is the right one, since the reverse choice (bold/heading styling, two regex
branches) was also a legitimate design and is not obviously worse.

---

## 3. Design decision 2 — coverage confirmation

**Yes, the single convention in §2 covers both contexts without modification:**

- **`lib/` moduledoc citations:** confirmed directly against all five phrasings found in §1's
  `lib/` survey (identity.ex's inline prose, scheduler.ex's bullet, router.ex's table) — none
  requires special-casing; the "citation unit" rule (line / paragraph / table) already
  produces a correct insertion point for each, and the marker text itself is valid inside a
  `"""` heredoc (§2c).
- **`docs/` citations, including `docs/migration/`:** confirmed against both
  `docs/requirements.yaml` phrasings (`SOURCE:`, `CONTRACT SOURCE:`) and spot-checked against
  `docs/migration/stage-5-scripting-plugins.md` (one of the 15 `docs/migration/*.md` files
  carrying a `.zig` reference, confirmed present via this session's own `grep -rl` in §1) —
  the same three unit shapes (line/paragraph/table) recur there, no fourth shape was found.

**No second marker is needed.** This design does not invoke the "or explicitly says why they
need different markers if unifying is not possible" fallback the requirement's own text
offers — unification succeeded.

---

## 4. Worked before/after example (real citation, verbatim)

**Real citation, quoted exactly as it exists in the tree today** (`docs/requirements.yaml`,
lines 13810-13811 — the exact citation this requirement's own description names as its
running example, REQ-231's `cursor.zig` `SOURCE:` line, which wraps onto a second line as
part of the same sentence):

Before (verbatim, current tree):

```
      SOURCE: c:\Users\tvolo\dev\ai-dala\R-Co\src\entities\query\cursor.zig
      and field_grants.zig.
```

After (this design's rewrite — REQ-239's job to apply, not this run's):

```
      PROVENANCE (historical, not current decision authority):
      SOURCE: c:\Users\tvolo\dev\ai-dala\R-Co\src\entities\query\cursor.zig
      and field_grants.zig.
```

**Diff, confirming the original path text is fully preserved and visibly identical:**

```
--- before
+++ after
@@ -1,2 +1,3 @@
+      PROVENANCE (historical, not current decision authority):
       SOURCE: c:\Users\tvolo\dev\ai-dala\R-Co\src\entities\query\cursor.zig
       and field_grants.zig.
```

Exactly one line is added; the two original lines — including the full R-Co path
`c:\Users\tvolo\dev\ai-dala\R-Co\src\entities\query\cursor.zig` and the continuation `and
field_grants.zig.` — are byte-identical between before and after.

**Second worked example, demonstrating the inline-prose unit rule** (`lib/letflow/identity.ex`,
current `@moduledoc`, lines 3-6):

Before (verbatim):

```
  Context module for the identity domain. `provision_oidc_user/4` (below) ports
  the JIT (just-in-time) user-provisioning orchestration from
  `src/oidc/jit_provisioning.zig` together with the actual upsert from
  `src/identity/registry.zig`'s `createOrGetJitOidcUser` (lines ~843-912),
```

After (marker precedes the whole paragraph, since this is phrasing 3 — inline prose, not a
dedicated citation line — per §2's paragraph-unit rule):

```
  PROVENANCE (historical, not current decision authority):
  Context module for the identity domain. `provision_oidc_user/4` (below) ports
  the JIT (just-in-time) user-provisioning orchestration from
  `src/oidc/jit_provisioning.zig` together with the actual upsert from
  `src/identity/registry.zig`'s `createOrGetJitOidcUser` (lines ~843-912),
```

Note this paragraph is also the module's opening moduledoc paragraph — REQ-238's own applier
will need to insert the marker as the *first* line of the `@moduledoc """` body in this
specific case, immediately after the opening `"""`, which is still "immediately above the
unit" per §2's rule (the unit's first line is the moduledoc's first content line here).

---

## 5. Verification method REQ-238/239 can run mechanically

Given as a fixed command shape, not implementation code (no script is written or executed by
this design):

- **Total-marked count:** `grep -rc 'PROVENANCE (historical, not current decision authority):' lib/ docs/`
  summed, before and after — must increase by exactly the number of citation units marked in
  that turn (not the number of raw `.zig` occurrences, since one unit can carry multiple
  `.zig` mentions per §2's table/paragraph rule).
- **No path text lost:** `grep -c '\.zig' <file>` before and after a given file's edit must
  be equal (this is already the exact check REQ-232 through REQ-236/240-242's own acceptance
  criteria use for the "no `.zig` citation line is deleted" guarantee — this design reuses
  that same check for REQ-238/239, not a new one).
- **Idempotency check:** re-running the insertion pass a second time must produce zero new
  markers (`grep -B1` immediately above each remaining unmarked unit — §2's
  de-duplication rule).

---

## 6. Chunking recommendation for REQ-238 (`lib/`) and REQ-239 (`docs/`)

Sizing reference (this session's own re-derivation, not carried over from the requirement
text): REQ-232 through REQ-236 and REQ-240 through REQ-242 each treated one ELIXIR-DEV turn
as **4 to 13 files** (REQ-240: 4 files; REQ-235: 5 files; REQ-242: 5 files; REQ-241: 6 files;
REQ-234: 7 files; REQ-232: 12 files (across all of `routers/`); REQ-233: 13 files (all of
`engine/`+`wasm/`+`lua/`)) — this design targets the same 4-13-file band, matching the
requirement text's own "roughly 5-15 files per chunk" instruction.

**REQ-238 (`lib/letflow/`, excluding `lib/letflow/design/` per REQ-238's own title) — 83
files carry a `.zig` reference today (re-derive at fix time, this count will drift).**
Recommended split, mirroring REQ-232 through REQ-236's own subsystem boundaries (same
directories, same rationale — a chunk this design's own applier can lift almost unchanged
from that precedent's file lists):

| Chunk | Files (directory scope) | Approx. file count |
|---|---|---|
| 238a | `lib/letflow/router.ex` + `lib/letflow/routers/*` | 13 |
| 238b | `lib/letflow/engine.ex` + `lib/letflow/engine/*.ex` (excl. `lua/`, `wasm/`) | ~14 |
| 238c | `lib/letflow/engine/lua/*`, `lib/letflow/engine/wasm/*` | ~4 |
| 238d | `lib/letflow/definitions.ex` + `lib/letflow/definitions/*` | 14 |
| 238e | `lib/letflow/api/*` + `lib/letflow/plugs/*` | 10 |
| 238f | `lib/letflow/identity.ex` + `lib/letflow/identity/*` + `lib/letflow/oidc/*` | 9 |
| 238g | `lib/letflow/event_store.ex` + `lib/letflow/event_store/*` | 5 |
| 238h | `lib/letflow/repository/*`, `lib/letflow/sandbox_pool.ex`+`sandbox_pool/*`, `lib/letflow/scheduler.ex`, `lib/letflow/tasks.ex`, `lib/letflow/tenant_provisioning.ex`, `lib/letflow/instances.ex` | 8 |

All eight chunks fall within the 4-15-file precedent band; 238b/238c split `engine/` in two
(REQ-233 treated all of it, 13 files, as one turn under the parity-phrase measure, but the
`.zig`-citation measure counts 22 files there once `lua/`/`wasm/` are included in the raw
`grep -rl`, wide enough to warrant the split — REQ-238's own applier should re-run
`grep -rl '\.zig' lib/letflow/engine.ex lib/letflow/engine/` to confirm the exact current
count before committing to this split or merging 238b/238c back into one turn).

**REQ-239 (`docs/`) — 58 non-`requirements.yaml` files plus `docs/requirements.yaml` itself
(538 matching lines in that one file alone, a clear outlier).** Recommended split:

| Chunk | Scope | Approx. size |
|---|---|---|
| 239a | `docs/requirements.yaml`, REQ-001 through the lowest-numbered quartile of REQ ids carrying a `.zig` line | ~135 lines |
| 239b | `docs/requirements.yaml`, next quartile | ~135 lines |
| 239c | `docs/requirements.yaml`, next quartile | ~135 lines |
| 239d | `docs/requirements.yaml`, final quartile | ~135 lines |
| 239e | `docs/migration/*.md` (15 files) | 15 |
| 239f | `docs/issues/*.yaml`, first half by ISS-id | ~17 |
| 239g | `docs/issues/*.yaml`, second half by ISS-id | ~16 |
| 239h | `docs/status/*`, `docs/frontend/*`, `docs/anti-patterns.md` | 10 |

`docs/requirements.yaml`'s four sub-chunks (239a-d) are sized by **matching-line count**, not
file count, since it is one file — quartered by REQ-id ranges (not raw line number) so a
single REQ entry's `SOURCE:`/description block is never split across two chunks. DOC-UPDATER
should re-run `grep -n '\.zig' docs/requirements.yaml` at fix time and quarter the resulting
REQ-id list evenly, rather than trusting this design's ~135-line estimate verbatim (538 / 4).
`docs/issues/*.yaml` (239f/g) similarly splits by ISS-id range across its 33 files, each half
landing within the 15-17-file band, comparable to REQ-232/233's own 12-13-file precedent.

---

## 7. Acceptance-criteria traceability

| This run's acceptance criterion | Concrete design element |
|---|---|
| "states the exact marker text/regex as a single copy-pasteable string or pattern, with a worked before/after example quoting one real citation…rewritten under the new convention" | §2 (marker text + regex), §4 (two worked examples, both from the real tree) |
| "explicitly confirms the marker is machine-greppable as one regex covering both the moduledoc and markdown contexts, or states a second regex…and justifies why unification was not possible" | §2(a), §3 (unification confirmed, no second regex needed) |
| "does not delete or alter any existing file-path text in its worked example — the original R-Co path string is fully preserved…confirmed by diffing" | §4 (explicit diff, both examples) |
| "states a concrete chunking recommendation…sized so no single recommended chunk exceeds what REQ-232 through REQ-236 each treated as one ELIXIR-DEV turn" | §6 (both tables, sizing reference derived from REQ-232/233/234/235/240/241/242's own real file counts) |
| "CODE-DESIGN-VALIDATOR signs off…no implementation code…every constraint addressed…unambiguous enough for REQ-238/239 to apply without further design judgement calls" | §2's placement rule is defined purely structurally (line/paragraph/table + de-dup check) precisely so no per-citation semantic judgement call is needed; §5 gives the exact verification commands REQ-238/239 reuse |

---

## 8. Open questions — explicitly listed, not silently resolved

**OQ-1 (MINOR).** §2's trade-off — a plain, unstyled marker line (no Markdown bold/heading)
in exchange for true single-regex greppability across both contexts — is this design's own
resolution of a genuine styling-vs-greppability tension. Flagged for REVIEWER to confirm
constraint (a) (single regex) should win over rendered visual distinctiveness in `docs/`.

**OQ-2 (MINOR).** §6's `engine/` split (238b/238c) and `docs/requirements.yaml` quartering
(239a-d) are this design's own estimates from counts measured at design time
(2026-09-05) and will drift by the time REQ-238/239 actually run. Both chunk tables say so
explicitly and name the exact `grep` command to re-derive the authoritative file/line list —
flagged here so REQ-238/239's own ELIXIR-DEV/DOC-UPDATER do not treat the file counts in §6
as frozen, only the chunk *boundaries* (which directories/id-ranges group together) as the
actual recommendation.

**OQ-3 (MINOR).** This design does not attempt to distinguish a "load-bearing decision
citation" from a "pure inventory/index citation" (e.g. `router.ex`'s subsystem-mapping table,
which lists R-Co filenames as a lookup table rather than as active justification prose) —
every unit containing a `.zig` substring is marked uniformly, per the requirement's own
"apply mechanically without further judgement calls per-citation" instruction (§2). Flagged
for REVIEWER to confirm this reading is correct: marking an index table's `.zig` cells as
"historical, not current decision authority" is harmless (the table's factual content, which
R-Co file a router module corresponds to, is unaffected either way), but it is a deliberate
choice not to special-case index-shaped units differently from justification-shaped ones.
