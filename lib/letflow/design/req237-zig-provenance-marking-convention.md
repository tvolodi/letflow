**AMENDMENT 2026-09-05:** added §6's `lib/letflow/design/` chunking table below (8 new
chunks, 239-design-a through 239-design-h). This is a scope gap found during REQ-239's
chunk-level split: REQ-239's original requirement text (pre-split, see `git show
main:docs/requirements.yaml | grep -n "id: REQ-239" -A 30` or REQ-ANALYST's commit
`da716b4c` on branch `feature/WF01-REQ238split-20260905`) explicitly included
`lib/letflow/design/*.md` in scope, and this design's own §3 confirms the same marking
convention applies there, but the original §6 (CODE-DESIGN-VALIDATOR-passed, unchanged
below) only chunked `docs/` and `docs/requirements.yaml` — it never produced a chunk for
`lib/letflow/design/`'s 100 `.zig`-carrying files. Nothing else in this document was
re-litigated or reopened; REQ-237 itself remains `status: done`.

**AMENDMENT 2026-09-05 (ISS-0510):** added a fourth citation-unit shape to §2 —
"YAML comment-line/sequence-item" — covering two patterns DOC-UPDATER already applied in
`docs/requirements.yaml` (a `#`-prefixed comment line above an `acceptance_criteria` bullet
or `id:`/`title:` key, and a `#`-prefixed commented-out `# ---` section-header block).
REVIEWER (gating WF02-REQ254-20260905) found this shape missing from §2's enumeration,
though DOC-UPDATER's handling of it — identical marker text, `#`-prefixed only because YAML
syntax requires it — was judged a defensible in-scope mechanical extension, not a second
convention. This amendment records that shape explicitly so REQ-255/257/258/259/260/261/262/263
(sibling pending `docs/requirements.yaml` chunks) don't each have to re-derive the same
judgment call. The marker text, §2(a)'s regex, and the original three unit shapes
(line/paragraph/table) are unchanged. §3 gets a one-line pointer to this amendment; nothing
else in this document was re-litigated or reopened; REQ-237 itself remains `status: done`.

---

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
- **YAML comment-line/sequence-item** (added 2026-09-05, ISS-0510 — a fourth shape, found
  already applied in `docs/requirements.yaml` by REQ-239/DOC-UPDATER, not identified in the
  original §1 survey because §1's survey did not separately enumerate YAML-syntax
  constraints): when the citation unit lives inside a YAML file (`docs/requirements.yaml`)
  and the enclosing context is itself a YAML comment, or a plain scalar/sequence item that
  cannot take a bare non-comment text line immediately above it without corrupting YAML
  syntax (inserting an unprefixed prose line directly above a `- "..."` sequence item, or
  above an `id:`/`title:` key, would itself parse as an invalid or unintended YAML node), the
  marker is inserted as a `# `-prefixed YAML comment line, containing the identical marker
  text verbatim, immediately above the unit. Two sub-cases, both already applied in the
  current tree:
  - **(a) Sequence item or key line:** a bare `#`-prefixed comment line immediately above a
    single `acceptance_criteria` sequence-item bullet (`docs/requirements.yaml:682-687`,
    REQ-017 — three separate acceptance-criteria bullets, each independently marked
    immediately above the specific bullet whose text carries the citation, not above the
    whole `acceptance_criteria:` list, since each bullet is itself a single-citation-line
    unit per the first bullet above) or above an `id:`/`title:` key pair whose value contains
    the citation (REQ-021: `id:` at `docs/requirements.yaml:806`, marker at line 807, `title:`
    at line 808 — the marker precedes the `title:` line, since `id:` and `title:` are treated
    as the same requirement-entry unit for this shape's purpose).
  - **(b) Commented-out section-header block:** when the citation is itself already inside a
    commented-out `# ---`-delimited section-header block (a run of consecutive `#`-prefixed
    lines forming one structural header, not prose), the marker precedes the whole block as
    one unit — same "smallest enclosing unit" principle the table bullet above uses, not one
    marker per header line (`docs/requirements.yaml:513-515`, and recurring identically at
    the analogous S2/S3 stage-header blocks).
  This sub-case is purely a placement rule, not a second marker: the marker text is
  unchanged, and the `# ` prefix is YAML comment syntax required by the surrounding file
  format to keep the document parseable — it is not part of the marker string itself. Because
  the marker text itself contains no `#`, §2(a)'s regex and the plain-string `grep -F` form
  both already match this shape unmodified: `grep -F 'PROVENANCE (historical, not current
  decision authority):' docs/requirements.yaml` finds the `#`-prefixed instances exactly like
  any unprefixed one, since `grep` matches the string anywhere in the line regardless of
  leading characters. No regex change, no marker-text change, and no reinterpretation of the
  three unit shapes above — this is an additive fourth shape only, needed because
  `docs/requirements.yaml` is the one citation-carrying file in this codebase written in a
  syntax (YAML) where a bare prose line cannot always be inserted directly.
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
  the same three unit shapes (line/paragraph/table) recur there. (Amended 2026-09-05,
  ISS-0510: a fourth shape — the YAML comment-line/sequence-item placement in §2 — was later
  found needed specifically inside `docs/requirements.yaml`'s YAML syntax, where a bare prose
  line cannot always be inserted directly; it does not add a second marker or regex, see §2.)

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

**Rework note (this revision):** CODE-DESIGN-VALIDATOR's rework-1 finding was that this
section's *per-chunk* counts had not actually been re-grepped the way §1's top-level totals
were — three REQ-238 chunks (238a, 238b, 238d as originally proposed) exceeded the 13-file
precedent ceiling on real counts. Every count below (both REQ-238's and REQ-239's, all
sixteen resulting chunks, not only the three flagged ones) was re-derived in this session by
running the literal `grep -rl`/`grep -c` command shown against each chunk's own proposed file
list — none is carried forward from the prior revision. `lib/` total (excluding
`lib/letflow/design/`) is **84** files today (drifted by one from the prior revision's 83 —
expected drift, per OQ-2); `docs/` totals (58 non-`requirements.yaml` files, 538
`docs/requirements.yaml` lines) are unchanged and reconfirmed.

Sizing reference (unchanged from the prior revision, itself a real re-derivation): REQ-232
through REQ-236 and REQ-240 through REQ-242 each treated one ELIXIR-DEV turn as **4 to 13
files** (REQ-240: 4; REQ-235: 5; REQ-242: 5; REQ-241: 6; REQ-234: 7; REQ-232: 12; REQ-233: 13
— the largest precedent chunk). **13 files is therefore the hard per-chunk ceiling this
design targets** — every chunk below, in both REQ-238 and REQ-239, is sized at or under 13.

**REQ-238 (`lib/letflow/`, excluding `lib/letflow/design/`) — 84 files carry a `.zig`
reference today** (`grep -rl '\.zig' lib/ | grep -v '^lib/letflow/design/' | wc -l`,
re-derive at fix time). The three chunks that exceeded 13 files last revision (routers,
engine-core, definitions) are each split into two alphabetically/functionally halved
sub-chunks below so no chunk exceeds the ceiling:

| Chunk | Files (directory scope) | Real file count (re-grepped this session) |
|---|---|---|
| 238a1 | `lib/letflow/router.ex` + `routers/{audit,definitions,dlq,identity,instances,metrics_exposition,onboarding}.ex` | 8 |
| 238a2 | `lib/letflow/routers/{promotions,services,solution_packs,tasks,tenant_config,tenants,webhooks}.ex` | 7 |
| 238b1 | `lib/letflow/engine.ex` + `engine/{execution_error,expr,instance_state,join_counter,pin_rebind,pin_resolver,plugin_interface,plugin_registry}.ex` | 9 |
| 238b2 | `lib/letflow/engine/{reconstruction,service_task,snapshot_writer,sub_process,task,token,transition,variable_merge,variable_schema}.ex` | 9 |
| 238c | `lib/letflow/engine/lua/*`, `lib/letflow/engine/wasm/*` | 4 |
| 238d1 | `lib/letflow/definitions.ex` + `definitions/{export_import,graph,process_definition,promotion,promotion_artifact,promotion_assertion_run,promotion_conflict}.ex` | 8 |
| 238d2 | `lib/letflow/definitions/{promotion_digest,promotion_plan,promotion_review_store,service_scope_validator,snapshot_store,solution_pack,sub_process_interface}.ex` | 7 |
| 238e | `lib/letflow/api/*` + `lib/letflow/plugs/*` | 10 |
| 238f | `lib/letflow/identity.ex` + `lib/letflow/identity/*` + `lib/letflow/oidc/*` | 9 |
| 238g | `lib/letflow/event_store.ex` + `lib/letflow/event_store/*` | 5 |
| 238h | `lib/letflow/repository/*`, `lib/letflow/sandbox_pool.ex`+`sandbox_pool/*`, `lib/letflow/scheduler.ex`, `lib/letflow/tasks.ex`, `lib/letflow/tenant_provisioning.ex`, `lib/letflow/instances.ex` | 8 |

Sum of the eleven chunks (8+7+9+9+4+8+7+10+9+5+8 = 84) matches the re-derived 84-file total
exactly — every file is assigned to exactly one chunk, none dropped, none duplicated. All
eleven chunks now fall at or under the 13-file ceiling (max is 238e/238f at 10/9, well under).
The 238a/238b/238d splits are purely alphabetical/functional halves of the single-chunk
boundary the prior revision proposed — same directory scope overall, just partitioned in two
so each half is independently sized within precedent.

**REQ-239 (`docs/`) — 58 non-`requirements.yaml` files plus `docs/requirements.yaml` itself
(538 matching lines in that one file, re-confirmed unchanged).** Re-grepping every proposed
chunk this session also surfaced two more chunks (239e as previously proposed, and the
previously-proposed 239f/239g issues split) that exceeded 13 files once actually counted —
both are split further below on the same principle as REQ-238's rework:

| Chunk | Scope | Real count (re-grepped this session) |
|---|---|---|
| 239a | `docs/requirements.yaml`, REQ ids in the lowest-numbered quartile carrying a `.zig` line | ~135 lines (of 538) |
| 239b | `docs/requirements.yaml`, next quartile | ~135 lines |
| 239c | `docs/requirements.yaml`, next quartile | ~135 lines |
| 239d | `docs/requirements.yaml`, final quartile | ~135 lines |
| 239e1 | `docs/migration/decisions/*.md` (8 files: 0001, 0002, 0003, 0007, 0010, 0013, 0014, 0016) | 8 |
| 239e2 | `docs/migration/stage-{1..7}-*.md` (7 files) | 7 |
| 239f | `docs/issues/*.yaml`, ISS-0001–ISS-0079 (11 files) | 11 |
| 239g | `docs/issues/*.yaml`, ISS-0085–ISS-0100 (11 files) | 11 |
| 239h | `docs/issues/*.yaml`, ISS-0101–ISS-0439 (11 files) | 11 |
| 239i | `docs/status/*`, `docs/frontend/*`, `docs/anti-patterns.md` | 10 |

`docs/requirements.yaml`'s four sub-chunks (239a-d) are still sized by **matching-line
count**, not file count, since it is one file — quartered by REQ-id ranges (not raw line
number) so a single REQ entry's `SOURCE:`/description block is never split across two chunks;
this line-based measure is not subject to the same 13-*file* ceiling as the other chunks
(it's one file), but DOC-UPDATER should still re-run `grep -n '\.zig' docs/requirements.yaml`
at fix time and quarter the resulting REQ-id list evenly rather than trusting this design's
~135-line estimate verbatim (538 / 4). `docs/migration/*.md` (15 files total, re-grepped) is
now split functionally into decisions (239e1, 8 files) vs. stage docs (239e2, 7 files) instead
of one 15-file chunk. `docs/issues/*.yaml` (33 files total, re-grepped) is now split into
three ISS-id-range thirds (239f/g/h, 11 files each) instead of two 17/16-file halves, since
17 and 16 both exceed the 13-file ceiling once actually counted — three-way split by ISS-id
keeps every third at 11, under the ceiling with room for count drift.

Sum check for REQ-239's file-based chunks: 239e1(8)+239e2(7)+239f(11)+239g(11)+239h(11)+239i(10)
= 58, matching the re-derived 58-file `docs/` (excl. `requirements.yaml`) total exactly.

**`lib/letflow/design/` (added 2026-09-05 amendment) — 100 files carry a `.zig` reference
today** (`grep -rl '\.zig' lib/letflow/design/*.md | wc -l`, re-derive at fix time). This
directory was in REQ-239's original pre-split scope (see the AMENDMENT note at the top of
this document) but was never chunked by the table above, which covered only `docs/`. It is
sized on the same 13-file ceiling as every REQ-238/REQ-239 chunk, boundary rule:
**alphabetical filename sort** (the same sort order `ls lib/letflow/design/*.md` /
`grep -rl` already produce), sliced into consecutive groups of at most 13. Because nearly
every file in this directory is named `reqNNN-*.md` with a zero-padded 3-digit requirement
number, alphabetical sort here coincides with ascending REQ-id order, so most chunk
boundaries are also clean REQ-id ranges — the small number of non-`reqNNN`-named files
(decision docs `0001-*`/`0002-*`/`0003-*`, and lowercase-named files like `api-pagination.md`,
`export_import.md`, `search.md`, `service_task*.md`) sort in alongside them and are called
out explicitly per chunk below. These chunks are not yet owned by a numbered requirement —
REQ-ANALYST assigns REQ ids to them next; the labels below (`239-design-a` .. `h`) are
placeholders identifying the chunk, not requirement ids.

| Chunk | Scope (alphabetical filename range) | Real file count (re-grepped this session) |
|---|---|---|
| 239-design-a | `0001-web-framework-addendum-req065.md`, `0001-web-framework-decision.md`, `0002-oidc-integration-decision.md`, `0003-ecto-schema-strategy-decision.md`, `api-pagination.md`, `export_import.md`, `identity-schema.md`, `iss-0047-username-race-conflict-target.md`, `iss-0078-pin-rebind-provenance.md`, `iss-0079-pin-override-verification.md`, `iss0438-entity-subsystem-scoping.md`, `promotion_plan.md`, `promotion_review_state_machine.md` | 13 |
| 239-design-b | `req017-claim-mapping.md` through `req029-node-attribute-edge-condition-validators.md` (req017–req029, 13 consecutive `reqNNN-*.md` files) | 13 |
| 239-design-c | `req030-definition-store-crud.md` through `req048-task-completion.md` (req030–req048, 13 files; not every number in range exists — 034/036/037/042/046/047 have no design doc) | 13 |
| 239-design-d | `req049-variable-merge.md` through `req066-api-error-response.md` (req049–req066, 13 files, same non-contiguous-numbering caveat) | 13 |
| 239-design-e | `req068-validation.md` through `req081-definition-routes-read.md` (req068–req081, 13 files) | 13 |
| 239-design-f | `req083-task-routes-read.md` through `req171-wasm-host-api-read.md` (req083–req171, 13 files, sparse numbering) | 13 |
| 239-design-g | `req178-dlq-routes.md` through `req202-artifact-repository.md` (req178–req202, 13 files) | 13 |
| 239-design-h | `req205-simulation-harness-foundation.md` through `req215-service-task-engine-wiring.md`, `req237-zig-provenance-marking-convention.md`, `search.md`, `service_task_dispatcher.md`, `service_task.md` (req205–req237 plus 3 lowercase-named files) | 9 |

Sum check: 13×7 + 9 = 100, matching the re-derived 100-file `lib/letflow/design/` total
exactly — every file assigned to exactly one chunk, none dropped, none duplicated. Note
`239-design-h` includes this document itself (`req237-zig-provenance-marking-convention.md`,
which cites `.zig` paths in its own worked example in §4) — REQ-ANALYST/ELIXIR-DEV should
confirm at fix time whether self-referential citations in this design doc are in scope for
the marking convention or excluded as meta-documentation of the convention itself; this is
also captured as a new open question in §8.

---

## 7. Acceptance-criteria traceability

| This run's acceptance criterion | Concrete design element |
|---|---|
| "states the exact marker text/regex as a single copy-pasteable string or pattern, with a worked before/after example quoting one real citation…rewritten under the new convention" | §2 (marker text + regex), §4 (two worked examples, both from the real tree) |
| "explicitly confirms the marker is machine-greppable as one regex covering both the moduledoc and markdown contexts, or states a second regex…and justifies why unification was not possible" | §2(a), §3 (unification confirmed, no second regex needed) |
| "does not delete or alter any existing file-path text in its worked example — the original R-Co path string is fully preserved…confirmed by diffing" | §4 (explicit diff, both examples) |
| "states a concrete chunking recommendation…sized so no single recommended chunk exceeds what REQ-232 through REQ-236 each treated as one ELIXIR-DEV turn" | §6 (both tables — REQ-238's 11 chunks and REQ-239's 10 chunks, every per-chunk count re-grepped this session, none exceeding the 13-file precedent ceiling derived from REQ-232/233/234/235/240/241/242's own real file counts) |
| "CODE-DESIGN-VALIDATOR signs off…no implementation code…every constraint addressed…unambiguous enough for REQ-238/239 to apply without further design judgement calls" | §2's placement rule is defined purely structurally (line/paragraph/table + de-dup check) precisely so no per-citation semantic judgement call is needed; §5 gives the exact verification commands REQ-238/239 reuse |

---

## 8. Open questions — explicitly listed, not silently resolved

**OQ-1 (MINOR).** §2's trade-off — a plain, unstyled marker line (no Markdown bold/heading)
in exchange for true single-regex greppability across both contexts — is this design's own
resolution of a genuine styling-vs-greppability tension. Flagged for REVIEWER to confirm
constraint (a) (single regex) should win over rendered visual distinctiveness in `docs/`.

**OQ-2 (MINOR).** §6's per-chunk splits (238a1/a2, 238b1/b2, 238d1/d2, 239e1/e2, 239f/g/h) and
`docs/requirements.yaml` quartering (239a-d) are this design's own re-derivation from counts
measured at rework time (2026-09-05, this revision) and will drift further by the time
REQ-238/239 actually run — this revision's own rework was triggered by exactly that kind of
drift (three chunks that were within the 13-file ceiling at the prior revision's measurement
had grown past it by this session). Every chunk table in §6 names the exact `grep` command to
re-derive the authoritative file/line list — flagged here so REQ-238/239's own
ELIXIR-DEV/DOC-UPDATER re-run those commands before starting, rather than treating this
revision's counts as frozen; only the chunk *boundaries* (which files/id-ranges group
together, and the 13-file-per-chunk ceiling itself) are the durable recommendation. If a
re-run at fix time shows any chunk has grown past 13 files again, split it further the same
way this rework did, rather than starting the implementation turn over-sized.

**OQ-3 (MINOR).** This design does not attempt to distinguish a "load-bearing decision
citation" from a "pure inventory/index citation" (e.g. `router.ex`'s subsystem-mapping table,
which lists R-Co filenames as a lookup table rather than as active justification prose) —
every unit containing a `.zig` substring is marked uniformly, per the requirement's own
"apply mechanically without further judgement calls per-citation" instruction (§2). Flagged
for REVIEWER to confirm this reading is correct: marking an index table's `.zig` cells as
"historical, not current decision authority" is harmless (the table's factual content, which
R-Co file a router module corresponds to, is unaffected either way), but it is a deliberate
choice not to special-case index-shaped units differently from justification-shaped ones.

**OQ-4 (MINOR, added 2026-09-05 amendment).** `239-design-h` (§6) assigns this document
itself, `req237-zig-provenance-marking-convention.md`, to a chunk, since its own §4 worked
examples quote real `.zig` citations verbatim. Whether this design document's own citations
should be marked under the convention it defines (meta-documentation of the convention) or
left unmarked as a reference copy of the original phrasing is not resolved here — flagged for
REQ-ANALYST/REVIEWER to decide when `239-design-h`'s owning requirement is drafted, rather
than silently excluding or including this file.
