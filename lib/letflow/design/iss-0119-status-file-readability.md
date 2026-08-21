# ISS-0119 — Fix design: restore an executable append-only safeguard for the requirement status history

**Run:** WF03-ISS0119-20260821 · **Step:** 2 (CODE-DESIGNER) · **Issue:** ISS-0119 (GH#373, queue task 186)
**Built on:** `handoffs/WF03-ISS0119-20260821/step-01-issue-fixer-diagnose.json` `result.summary`
**Implemented by:** ELIXIR-DEV at Step 3 (docs/process change; no `lib/` runtime code except the Step 4 test)

This is a design artefact. It contains no implementation. The one place finished prose
appears verbatim is the required new header/footer/index text — the handoff sanctions
that explicitly, because the defect *is* the current header's wording.

> **AMENDED 2026-08-21, AFTER THIS ARTEFACT PASSED ITS GATE — see §13.** Assertion A4 was
> implemented and run for the first time at Step 4 and found three previously undeclared
> malformed entries in frozen volume 1 (lines 4803, 4896, 5050). §13 is the amendment: a new
> `known_shape_anomalies:` index key, A4 split into A4a/A4b, A5 unchanged **at the time**,
> volume 1 not edited, `frozen_prefix_sha256` unchanged. §§1–12 are the gated design and carry
> only cross-reference markers to §13.
>
> **FURTHER AMENDED 2026-08-21 — ISS-0193 — see §13.6 and §13.12.** A4b's closed-and-pinned
> rule (above) had no counterpart on A5/`known_anomalies:`, so a new *vocabulary* violation in
> the current volume could be declared away with no gate tripped, exactly as the shape hole
> could before it was fixed. A5 gains the identical rule (§13.6). A new assertion **A10**
> (§13.12.4) asserts a closed volume actually exceeded `roll_rule` at closure, closing the
> separate laundering route (close-then-declare) CODE-DESIGN-VALIDATOR flagged as MINOR-4 at
> the same gate; both A4b and A5's closed-and-pinned checks now depend on it rather than each
> re-deriving it. Nothing in §§1–13.11 changes in substance except §13.6's own text and one
> bullet in §13.3.

---

## 1. Decision: BOTH (a) and (b), executed as one change

**Chosen remedy: (a) and (b) together, in a single Step 3 commit.** Neither is sufficient
alone, and the diagnosis says why in its own words.

**Why not (b) alone.** Remedy (b) rewrites the header to prescribe a scoped read. The
diagnosis rules that out as a complete fix on two independent grounds:

- *C7 (growth is not stopping).* "It leaves C7 unaddressed — the file keeps growing and
  the scoped-read window keeps covering a smaller fraction." A header-only fix makes the
  agent's window a smaller and smaller share of the file every week. It converts a hard,
  visible failure (a refusal) into a soft, invisible one (a compliant-looking partial
  read). That is a *worse* failure shape than today's, because today's refusal at least
  announces itself.
- *L2 was already weak before L1 broke.* The diagnosis's strongest finding is that the
  three `event: SCOPE-CHANGE` entries were written on 2026-08-17, when the file was
  234,147 bytes and read-in-full still worked: "the read-in-full link was already weak as
  a schema-transmission mechanism before it broke outright. Reading a file in full has
  never reliably caused an agent to notice a convention buried in one of 182 entries."
  Prescribing a *scoped* read of a file whose schema was already not being transmitted by
  a *full* read cannot be the whole answer. The schema has to be stated, not inferred —
  and it has to be stated somewhere an agent reliably lands.

**Why not (a) alone.** A split restores the literal full read but transmits nothing about
the schema; the diagnosis warns that "a guarantee that the header/schema documentation is
carried into every shard" is required, "otherwise the split multiplies the L2 problem
instead of fixing it." And a split leaves 23 instruction sites, `TASK_QUEUE.md:133`'s
wrong-field instruction, and the `core-directives.md:173` vs `:328` gap all untouched.

**Why both, and why in one commit.** The diagnosis's own summation: "Both remedies
independently require touching the section 2 contradiction; neither is complete without
it." The 23 instruction sites must be edited by (a) anyway; (b)'s edits land in the same
files (`core-directives.md:328`, `doc-updater.md:17/31`, `anti-patterns.md:68`). Splitting
this across two runs would leave the repo in a state where the instructions describe a
layout that does not exist. One commit, one consistent state.

**The specific shape chosen — freeze-and-roll, not a retroactive split.** This is the
design's load-bearing decision and it is driven by constraint C4. The diagnosis found ~103
immutable historical references under `handoffs/` and `test/reports/`, plus a
line-number citation at `lib/letflow/design/iss-0078-pin-rebind-provenance.md:367` that
cites `docs/status/requirement_status.yaml:5158` — verified structurally for this design:
line 5158 falls inside the `note:` prose of a REQ-059/PIN-05 entry, so *any* line inserted
or removed anywhere above it silently falsifies that citation.

Therefore: **the existing file is not split, not renamed, not reordered, and not edited
above its last line.** It is closed in place as Volume 1 and left byte-identical through
line 5,766. New appends go to a new, small, readable Volume 2. C4 is satisfied trivially —
every one of the ~103 historical references still resolves to a live path holding exactly
the content it referred to, and `:5158` still points at the same characters.

**The append-only rule is not relaxed. It is strengthened.** Nothing in this design permits
rewriting any past entry, in any volume, ever. Volume 1 becomes *more* protected than
before: it is frozen, and §7's invariant test hashes it so a silent rewrite fails CI. The
three malformed entries stay exactly as written (§5). What changes is only *which file the
next append lands in* and *how big any appendable file is allowed to get* — the mechanism,
not the rule. This satisfies C1 and the issue's explicit prohibition.

---

## 2. Target layout

| Path | Status after Step 3 | Role |
|---|---|---|
| `docs/status/requirement_status.yaml` | **Volume 1 — CLOSED, frozen** | The entire history to 2026-08-21. Lines 1–5,766 unchanged. A closure footer is *appended after* line 5,766. Never appended to again. |
| `docs/status/requirement_status.v2.yaml` | **Volume 2 — CURRENT** | New. Carries the full corrected header (§4). All new appends land here until it rolls. |
| `docs/status/requirement_status.index.yaml` | **New** | The fixed-name entry point. Names the current volume, every closed volume, the roll rule, and the declared anomalies. This is the file every instruction site points at. |

An agent never needs to know the volume-naming scheme: it reads the index (small, fixed
name, always readable), which names the current volume, which is guaranteed readable in one
call by §6's roll rule.

---

## 3. Exact changes, file by file

### 3.1 `docs/status/requirement_status.yaml` (Volume 1)

**Change:** append the following block after the current last line (5,766). **Nothing above
line 5,766 may be touched** — not the header, not whitespace, not a comment. Verified by
§7 assertion A6.

```yaml

# ─────────────────────────────────────────────────────────────────────────────
# VOLUME 1 — CLOSED 2026-08-21. DO NOT APPEND TO THIS FILE.
#
# This volume holds the complete requirement run history from 2026-08-13 through
# 2026-08-21 (182 entries, lines 1-5766). It is frozen: every line above this
# comment is preserved byte-for-byte, because ~103 historical run records under
# handoffs/ and test/reports/ cite this path, and
# lib/letflow/design/iss-0078-pin-rebind-provenance.md:367 cites line 5158 of it
# by number. Nothing here is rewritten, corrected, renumbered or moved. Reads of
# this volume are TARGETED reads only — a line range or a pattern match, never a
# whole-file read; it is 361,376 bytes and a whole-file read is refused by the
# Read tool. Use whichever your shell has:
#   Read tool with offset/limit (works everywhere), or
#   Bash:       grep -n PATTERN FILE   /   sed -n 'START,ENDp' FILE
#   PowerShell: Select-String -Path FILE -Pattern PATTERN
#               (Get-Content FILE)[START..END]
#
# NEW ENTRIES GO TO THE CURRENT VOLUME. Find it in:
#   docs/status/requirement_status.index.yaml
# which, as of this closure, names:
#   docs/status/requirement_status.v2.yaml
#
# Why this file was closed rather than split: ISS-0119. See
# lib/letflow/design/iss-0119-status-file-readability.md.
#
# KNOWN ANOMALIES IN THIS VOLUME, recorded and deliberately NOT corrected
# (correcting them would be rewriting past entries — the exact act this file's
# append-only rule exists to prevent):
#   line 3490 (REQ-031), line 3577 (REQ-042), line 3744 (REQ-038) — all agent
#   ORCH, 2026-08-17 — carry `event: SCOPE-CHANGE`. SCOPE-CHANGE is a `req:`
#   value, not an `event:` value (31 entries in this volume use it correctly).
#   These three followed docs/agents/protocols/TASK_QUEUE.md:133, which stated
#   the convention in the wrong field; that instruction is corrected as part of
#   ISS-0119. The entries stay as written. They are declared in the index under
#   `known_anomalies:` and the Step 4 invariant test asserts they are still
#   present and still wrong — a silent normalization fails the suite.
# ─────────────────────────────────────────────────────────────────────────────
```

**No entry is dropped:** the mechanism is that no entry is moved. There is no copy step, no
partition step, no rewrite step — only an append of comment lines at EOF. See §8 for how
this is verified.

### 3.2 `docs/status/requirement_status.v2.yaml` (Volume 2) — NEW

Created with the full header quoted in §4, followed by `history:` and no entries.
This run's own `done` event is appended by DOC-UPDATER at Step 6, not by ELIXIR-DEV at
Step 3.

### 3.3 `docs/status/requirement_status.index.yaml` — NEW

Exact required content (the `frozen_prefix_sha256` value is computed by ELIXIR-DEV at
Step 3 per §8 and pasted in place of the placeholder; nothing else is left to invention):

```yaml
# Requirement run-history index.
#
# THIS FILE IS THE ENTRY POINT. To append a status event, or to look one up, read
# this file first — it is small and always readable in one call — then act on the
# volume it names. Do not guess volume filenames; they are listed here.
#
# The run history is kept as a sequence of VOLUMES. Exactly one volume is
# `current` at a time; all others are `closed` and frozen. A volume is closed and
# a successor opened when it crosses the size ceiling below, so that the current
# volume is ALWAYS small enough to read in a single un-scoped Read call. That
# bound is the whole point: the append-only safeguard requires seeing the file's
# schema before appending, and a file too large to read cannot deliver it.
#
# The append-only rule is unchanged and absolute: entries are appended, never
# edited, never reordered, never deleted, in any volume, closed or current.

roll_rule:
  # Checked by DOC-UPDATER AFTER writing its entry, and by the Step 4 invariant
  # test on every `mix test` run. Measure the WORKING-TREE file (CRLF on Windows),
  # because that is what the Read tool measures.
  max_lines: 1200
  max_bytes: 120000
  read_tool_hard_limit_bytes: 262144   # headroom is deliberate, do not raise the ceiling
  read_tool_default_line_limit: 2000   # a "full read" past this silently truncates
  on_exceed: >
    Close the current volume (append the closure footer, set status: closed here),
    create the next volume with the SAME header text and an empty `history:` list,
    and set it current here. Full procedure: the "WHEN THIS VOLUME IS FULL" section
    of the current volume's own header.

volumes:
  - volume: 1
    path: docs/status/requirement_status.yaml
    status: closed
    opened: 2026-08-13
    closed: 2026-08-21
    entries: 182
    lines: 5766
    bytes_working_tree: 361376
    # SHA-256 of lines 1..5766 with CRLF normalised to LF, i.e. the frozen prefix.
    # The hashed stream terminates EVERY line with a single \n, including the
    # last, so it ends in \n. Exact definition and reference implementations:
    # lib/letflow/design/iss-0119-status-file-readability.md §8.
    # Asserted unchanged by test/docs/requirement_status_invariants_test.exs.
    frozen_prefix_lines: 5766
    frozen_prefix_sha256: "<computed at Step 3 — see design §8>"
    note: >
      Closed under ISS-0119 at 361,376 bytes, above the 262,144-byte read limit.
      Not split and not renamed: ~103 historical run records under handoffs/ and
      test/reports/ cite this path, and
      lib/letflow/design/iss-0078-pin-rebind-provenance.md:367 cites line 5158 by
      number. Freezing in place keeps every one of those citations valid.

  - volume: 2
    path: docs/status/requirement_status.v2.yaml
    status: current
    opened: 2026-08-21
    entries: 0
    note: Opened by ISS-0119's fix. Successor to volume 1.

known_anomalies:
  # Entries that do not conform to the documented vocabulary and are LEFT AS
  # WRITTEN, because correcting a past entry is precisely what the append-only
  # rule forbids. Declared here so they are discoverable without a survey, and so
  # the invariant test can distinguish "known, tolerated" from "new drift".
  # The test asserts this list matches the anomalies actually on disk EXACTLY:
  # a new undocumented value fails, and a silent normalisation of one of these
  # ALSO fails.
  - path: docs/status/requirement_status.yaml
    line: 3490
    req: REQ-031
    field: event
    value: SCOPE-CHANGE
    should_have_been: "req: SCOPE-CHANGE with event: done"
    cause: docs/agents/protocols/TASK_QUEUE.md:133 stated the convention in the wrong field
  - path: docs/status/requirement_status.yaml
    line: 3577
    req: REQ-042
    field: event
    value: SCOPE-CHANGE
    should_have_been: "req: SCOPE-CHANGE with event: done"
    cause: docs/agents/protocols/TASK_QUEUE.md:133 stated the convention in the wrong field
  - path: docs/status/requirement_status.yaml
    line: 3744
    req: REQ-038
    field: event
    value: SCOPE-CHANGE
    should_have_been: "req: SCOPE-CHANGE with event: done"
    cause: docs/agents/protocols/TASK_QUEUE.md:133 stated the convention in the wrong field
```

---

## 4. The exact required new header text (Volume 2, and every future volume)

This text is copied verbatim into `docs/status/requirement_status.v2.yaml` and into every
volume opened thereafter (only the `VOLUME n` line, the predecessor line, and the opening
date change).

**Shell coverage is part of the specification, not a formatting preference.** This repo runs
on Windows with PowerShell as the primary shell *and* Bash; `grep`, `sed`, `awk`, `wc` and
`date` do **not** exist in PowerShell (`grep --version` there returns
`The term 'grep' is not recognized as the name of a cmdlet, function, script file, or
operable program`). A procedure whose first step is a bare GNU-coreutils invocation is
therefore unexecutable for roughly half the sessions that run it — which is ISS-0119's own
defect reproduced inside ISS-0119's fix. **Every command in the header below is given as a
labelled Bash/PowerShell pair, or is a `git` invocation that is identical in both**, and no
step assumes a full read of a file that cannot be fully read. The both-shells precedent is
already set by `core-directives.md:156-161`. This rule binds every future volume header too:
a new volume is opened by copying this text verbatim, so a single-shell command introduced
here would propagate forever.

```yaml
# Letflow — Requirement run history — VOLUME 2 (CURRENT)
#
# docs/requirements.yaml's `status:` field is the current state of each
# requirement (pending/in_progress/done/blocked) — read that first. This file is
# the history behind it: one entry per time an agent picked up, finished, or got
# blocked on a piece of work.
#
# APPEND ONE ENTRY PER EVENT. NEVER REWRITE, REORDER, EDIT OR DELETE A PAST
# ENTRY — in this volume or any closed one. An agent once rewrote this history
# from scratch with different field names and silently destroyed prior entries;
# see docs/anti-patterns.md, "Overwriting docs/status/requirement_status.yaml
# instead of appending". That is what this rule exists to prevent, and it is not
# negotiable.
#
# VOLUMES. The history is split across volumes because a file too large to read
# cannot show you its own schema. Index (start here):
#   docs/status/requirement_status.index.yaml
# Predecessor: docs/status/requirement_status.yaml (volume 1, closed, frozen,
# 5,766 lines — targeted reads only, a whole-file read of it is refused).
#
# ── HOW TO APPEND (this is the procedure; it is executable, run it) ───────────
#
# 1. Confirm you are writing to the current volume. Never assume this file is it.
#    Run the ONE LINE for YOUR shell — grep does not exist in PowerShell, and
#    Select-String does not exist in bash. Each is a single line; do not wrap it:
#      Bash:
#        grep -n 'status: current' -B 2 docs/status/requirement_status.index.yaml
#      PowerShell:
#        Select-String -Path docs/status/requirement_status.index.yaml -Pattern 'status: current' -Context 2,0
#    Both print the `- volume:` / `path:` lines above the `status: current`
#    marker. The `path:` value they show is the file you append to.
#
# 2. Read THIS volume in full — one Read call on this path, no offset, no limit.
#    That is possible by construction: the roll rule below keeps every current
#    volume under 1,200 lines / 120,000 bytes, inside the Read tool's 256KB and
#    2,000-line limits. If that read is refused or truncated, STOP: the roll rule
#    has failed and that is itself a defect to file, not to work around.
#    Confirm both bounds before you rely on the read (lines AND bytes — a
#    line-truncated read is silent):
#      Bash:
#        wc -l < FILE ; wc -c < FILE
#      PowerShell:
#        (Get-Content FILE).Count ; (Get-Item FILE).Length
#    (FILE = docs/status/requirement_status.v2.yaml. PowerShell has no `&&`;
#    `;` chains unconditionally in both shells.)
#
# 3. Get the timestamp from the clock, never from memory:
#      Bash:       date -u +"%Y-%m-%dT%H:%M:%SZ"
#      PowerShell: (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
#
# 4. Append your entry at the end of the file. Append — do not open the file for
#    rewriting, do not regenerate it, do not reflow existing entries.
#    If you append via a Bash heredoc, the delimiter MUST be quoted (`<<'EOF'`,
#    never `<<EOF`): your note text will routinely contain backticks and colons
#    because it is prose ABOUT this file's own field names, and an unquoted
#    delimiter lets Bash execute a backtick span as a command substitution,
#    silently deleting it from what lands on disk (ISS-0199, hit live). In
#    PowerShell, use a literal here-string (`@'...'@`), never an interpolating
#    one (`@"..."@`), for the matching reason with `$`.
#
# 5. Verify you appended and did not replace, AND that what landed is what you
#    wrote — two checks, neither optional:
#      a. The line count must GROW:
#           git diff --numstat docs/status/requirement_status.v2.yaml
#         Any nonzero deletion count on this file is a defect. Revert and redo.
#         This proves you appended; it proves nothing about WHAT you appended —
#         a shell that silently ate a backtick span still line-balances.
#      b. Re-read what you just wrote:
#           Bash:       tail -n 8 docs/status/requirement_status.v2.yaml
#           PowerShell: Get-Content docs/status/requirement_status.v2.yaml -Tail 8
#         Confirm the note text reads exactly as you intended — no missing
#         words, no blank span where a backtick-quoted field name belonged.
#         This is the check (a) structurally cannot make: ISS-0199 was a real
#         append that passed (a) at `43\t0` while its note text had already
#         been silently gutted by an unquoted-heredoc command substitution.
#
# 6. Update this volume's `entries:` count in
#      docs/status/requirement_status.index.yaml
#    to match — increment it by one, in the SAME commit as your append. A
#    declared count nobody updates is a number nobody can trust; ISS-0199
#    finding 2 found this volume's `entries:` at 0 after real entries had
#    already landed. test/docs/requirement_status_invariants_test.exs's A9
#    asserts this count against what is actually on disk.
#
# 7. Apply the roll rule below.
#
# ── ENTRY SHAPE — all five fields, in this order, every time ──────────────────
#
#   - req: <REQ-NNN | SCOPE-CHANGE>
#     event: <started | done | blocked | cancelled | revised | verified>
#     agent: <AGENT_ID>
#     at: <UTC timestamp from the clock, not memory>
#     note: short free-text (what shipped, or what's blocking)
#
# ── `req:` — THE COMPLETE LIST. Exactly two legal values ──────────────────────
#
#   REQ-NNN        A requirement in docs/requirements.yaml. Three digits, zero-
#                  padded (REQ-003, not REQ-3). 151 entries in volume 1.
#   SCOPE-CHANGE   ANY work not tied to a requirement id: WF-03 issue
#                  resolutions, queue reconciliation, pipeline/process changes,
#                  manual bookkeeping. 31 entries in volume 1. Put the real
#                  subject (the ISS id, the run id, what was reconciled) in
#                  `note:`.
#
#   THERE IS NO THIRD VALUE. In particular: `req: ISS-NNNN` IS NOT LEGAL and has
#   zero precedent (0 occurrences across volume 1's 182 entries). Recording an
#   issue fix uses `req: SCOPE-CHANGE` with the ISS id named in `note:`. This is
#   written down here because it was previously discoverable only by surveying
#   the whole file, and `req: ISS-NNNN` is the obvious wrong guess.
#
# ── `event:` — THE COMPLETE LIST. Exactly six legal values ────────────────────
#
#   started    work picked up.                         (54 in volume 1)
#   done       work finished and merged.               (107 in volume 1)
#   blocked    work stopped on an external dependency.   (5 in volume 1)
#   cancelled  work abandoned; it will not be finished.  (8 in volume 1)
#   revised    a prior decision or scope was changed.    (4 in volume 1)
#   verified   independently re-verified after `done`.   (1 in volume 1)
#
#   Volume 1's original header listed only started|done|blocked, while
#   cancelled, revised and verified were already in use — an inaccuracy that
#   could only be found by reading 5,766 lines. All six are documented here.
#
#   SCOPE-CHANGE IS NOT AN EVENT VALUE. Three volume-1 entries (lines 3490,
#   3577, 3744) carry `event: SCOPE-CHANGE`. They are wrong, they are recorded
#   as known anomalies in the index, and they are LEFT AS WRITTEN — correcting a
#   past entry is exactly what this file forbids. Do not copy them, and do not
#   "clean them up".
#
#   Adding a seventh event value is a documentation change, not an improvisation:
#   amend this header in the same commit that first uses it, or use an existing
#   value. An undocumented value fails
#   test/docs/requirement_status_invariants_test.exs.
#
# ── WHEN THIS VOLUME IS FULL — the roll rule ──────────────────────────────────
#
# AFTER appending, measure this file (working tree, not the git blob — the Read
# tool measures the working tree, and CRLF checkouts add one byte per line):
#     Bash:       wc -l < FILE ; wc -c < FILE
#     PowerShell: (Get-Content FILE).Count ; (Get-Item FILE).Length
#
# If lines > 1200 OR bytes > 120000, roll before your handoff completes:
#   1. Append this volume's closure footer (copy volume 1's footer, adjusting the
#      volume number, dates, counts and successor path).
#   2. Create docs/status/requirement_status.v<n+1>.yaml containing THIS HEADER
#      TEXT verbatim — with the volume number, opening date and predecessor path
#      updated — followed by `history:` and no entries.
#   3. In docs/status/requirement_status.index.yaml: set this volume's status to
#      `closed`, fill its entries/lines/bytes/frozen_prefix_lines/
#      frozen_prefix_sha256, and add the new volume with `status: current`.
#   4. Commit all three files together. A closed volume with no successor, or two
#      current volumes, fails the invariant test.
#
# Rolling is normal maintenance, not an incident. It is expected roughly every
# 40 entries. It never moves, edits or deletes an existing entry.

history:
```

**Why this header is executable where the old one was not.** The old header's implied
procedure ("read it in full") became a tool refusal with no documented fallback. This one
names the read, states the bound that makes the read possible, gives real commands for
both shells, gives an append-verification command (`git diff --numstat`, a positive check
that deletions are zero), and defines what to do when the bound is next reached. Every step
is something an agent runs, not something it aspires to.

---

## 5. Vocabulary and the three malformed entries

> **AMENDED 2026-08-21 (post-gate) — see §13.** This section covers the three
> *vocabulary* anomalies (`event: SCOPE-CHANGE`). A4's first ever run found three
> *further*, separate volume-1 entries with a **shape** defect — two missing `note:`
> and one using `timestamp:` instead of `at:`. They are different entries, a different
> defect class, and a different declaration mechanism. §13 is normative for them; this
> section is unchanged and still normative for the vocabulary three.

Full vocabulary is quoted in §4 and is the normative statement. Summary of coverage against
the diagnosis's measured distribution — all 7 in-use `event` values accounted for:

| Value | In use | Disposition |
|---|---|---|
| `done` | 107 | Documented as legal. |
| `started` | 54 | Documented as legal. |
| `cancelled` | 8 | Documented as legal (was undocumented). |
| `blocked` | 5 | Documented as legal. |
| `revised` | 4 | Documented as legal (was undocumented). |
| `verified` | 1 | Documented as legal (was undocumented). |
| `SCOPE-CHANGE` | 3 | **Not legal as an event.** Declared as a known anomaly; entries left untouched. |

`req:` values: `REQ-NNN` (151) and `SCOPE-CHANGE` (31) are legal; nothing else is; `ISS-NNNN`
is explicitly called out as illegal with its zero-precedent count stated.

**Handling of the 3 malformed entries — designed honestly, per C2.** They are:

1. **Not edited.** Not in this run, not ever. Editing them is rewriting past entries (C1/C2).
2. **Not hidden.** Declared three times over — in volume 1's closure footer, in the index's
   `known_anomalies:`, and in the current volume's header — so any agent that lands on any
   of the three entry points sees them.
3. **Attributed.** Each declaration names the cause (`TASK_QUEUE.md:133`), so a reader
   understands they were compliance with a wrong instruction, not carelessness.
4. **Machine-pinned.** §7 assertion A5 asserts the on-disk anomaly set equals the declared
   set exactly. A *new* undocumented value fails the suite; so does a *silent normalization*
   of one of these three. The audit trail is protected in both directions — this is the
   design's answer to "corrected quietly at some later date".

---

## 6. Behaviour at the next growth threshold (C7)

This is the part that makes the fix not merely a clock reset.

- **Bound:** current volume ≤ 1,200 lines **and** ≤ 120,000 working-tree bytes.
- **Headroom rationale:** the Read tool refuses above 262,144 bytes and truncates
  above 2,000 lines by default. Both limits must be respected for "read in full" to mean
  what it says. The ceilings sit at ~46% of the byte limit and 60% of the line limit —
  enough that even the longest observed entry (~40 lines of `note:` prose) cannot carry a
  volume from under-bound to over-limit in one append.
- **Trigger point:** checked by DOC-UPDATER immediately *after* its append, so the volume
  that goes over is closed by the same agent that filled it, in the same commit. No
  deferred cleanup, no queued task, no chance for the next agent to hit a refusal.
- **Second, independent trigger:** §7 assertion A3 fails `mix test` if any current volume
  is over bound. Even if a DOC-UPDATER turn skips step 6, CI catches it on the next run —
  the safeguard no longer depends solely on an agent's diligence. This is the "second line
  of defence" the diagnosis found to be entirely absent.
- **Steady state:** at ~40 entries per volume and the observed rate, a roll happens every
  few weeks and costs one footer, one new file, one index edit. The scheme is unbounded:
  volume `n` always names volume `n+1`, and the index always names the current one, so
  there is no future threshold at which this problem recurs. ISS-0119 cannot happen again
  to a file that is bounded by construction and asserted by test.

---

## 7. Step 4 regression test — a mechanical invariant exists

**Something mechanical IS checkable here, and it directly re-detects ISS-0119.** New file:

**`test/docs/requirement_status_invariants_test.exs`** (ExUnit, no database, no new deps —
line-oriented parsing with the standard library plus `:crypto` for the digest; the files are
machine-regular: entries start with `  - req: ` and fields with four-space indent).

**Plus one support module — this is a design decision, not a detail, because it is what makes
the fail-first demonstration possible (see §7.1).**

**`test/support/status_history.ex`**, module `Letflow.Test.StatusHistory`. `mix.exs:20`
already compiles `test/support` in `:test`, so no build change is needed. Every check below
is a **pure function taking an explicit path or explicit bounds**, never reading a hardcoded
location:

- `parse_index(index_path) :: %{roll_rule: %{max_lines: pos_integer, max_bytes: pos_integer}, volumes: [%{volume:, path:, status:, frozen_prefix_lines:, frozen_prefix_sha256:}], known_anomalies: [%{path:, line:, field:, value:}]}`
- `measure(volume_path) :: %{lines: non_neg_integer, bytes: non_neg_integer}` — working tree,
  `File.stat!/1` for bytes
- `within_bounds?(volume_path, max_lines, max_bytes) :: :ok | {:error, %{lines:, bytes:, max_lines:, max_bytes:, over: [:lines | :bytes]}}`
- `entries(volume_path) :: [%{req:, event:, agent:, at:, line:}]`
- `anomalies(volume_path, legal_reqs, legal_events) :: [%{path:, line:, field:, value:}]`
- `frozen_prefix_digest(volume_path, line_count) :: String.t()` — the §8 byte-stream
  convention, lowercase hex
- `default_ceilings() :: {max_lines :: pos_integer, max_bytes :: pos_integer}` — `{1200, 120000}`.
  Used **only** by the degraded resolution below, when there is no index to read them from.
  Pinned to the index by A8, so it is a machine-checked copy, not a prose copy.
- `current_volume(index_path, status_dir) :: {:index, path} | {:no_index_fallback, path}` —
  the resolution rule §7.1 depends on. If `index_path` exists, parse it and return
  `{:index, <the volume whose status: is current>}`. **If and only if `index_path` does not
  exist, return `{:no_index_fallback, Path.join(status_dir, "requirement_status.yaml")}`** —
  the pre-index layout's one and only status file. The two-element tag is deliberate: a
  caller cannot consume the degraded answer without seeing that it is degraded.

The test file wires these to the real index; §7.1 wires `within_bounds?/3` to the pre-fix
state through `current_volume/2`. Nothing in the module knows that
`docs/status/requirement_status.index.yaml` exists — the index path is always passed in.

Assertions, all derived from the index file so the test never hardcodes a volume list:

- **A0 — The index exists and resolution is not degraded.**
  `StatusHistory.current_volume("docs/status/requirement_status.index.yaml", "docs/status")`
  returns an `{:index, _}` tuple, never `{:no_index_fallback, _}`. This is the guard that
  keeps §7.1's degraded path unreachable on any post-fix tree: if the index is ever deleted,
  renamed or corrupted, the suite goes red here rather than quietly resolving to volume 1.
- **A1 — Index/disk agreement.** Every `path:` in `volumes:` exists; every file matching
  `docs/status/requirement_status*.yaml` on disk appears in `volumes:`. No orphan volume,
  no dangling entry.
- **A2 — Exactly one current volume.** Exactly one entry has `status: current`; all others
  `closed`.
- **A3 — THE ISS-0119 REGRESSION ASSERTION, and the fail-first test.** Resolve the current
  volume with `StatusHistory.current_volume/2` (**not** by hardcoding a path), then assert
  `StatusHistory.within_bounds?(current_volume_path, max_lines, max_bytes)` returns `:ok`,
  where the bounds are `roll_rule.max_lines`/`roll_rule.max_bytes` when the index resolved
  and `StatusHistory.default_ceilings()` when it did not. **This single assertion is the
  fail-first demonstration** — see §7.1 for why, and for the exact procedure that shows it
  failing on the pre-fix commit. A3b (§7.1) is a separate detector-calibration guard, not
  the fail-first proof.
- **A4 — Vocabulary conformance. ⚠ AMENDED 2026-08-21 (post-gate) — §13 is normative;
  read it before implementing A4.** Across every volume, every `req:` value matches
  `REQ-\d{3}` or `SCOPE-CHANGE`; every `event:` value is one of the six legal values; every
  entry carries all five fields in order with a parseable ISO-8601 `at:`. Exceptions only
  as declared in A5. **§13 splits this into A4a (vocabulary, exceptions declared in the
  index's `known_anomalies:` — unchanged) and A4b (shape, exceptions declared in the
  index's new `known_shape_anomalies:`), and states the exact behaviour of each.**
- **A5 — Anomaly set is exact (protects C2 in both directions). ⚠ AMENDED 2026-08-21
  (ISS-0193) — §13.6/§13.12 are normative; read them before implementing A5.** *(§13
  originally confirmed A5 was substantively unchanged: scoped to vocabulary violations only,
  its three declared entries untouched, ignoring `known_shape_anomalies:` entirely. That part
  still holds. §13.6 as amended by ISS-0193 adds one more thing: A5 gains A4b's
  closed-and-pinned rule.)* The set of vocabulary violations found on disk, keyed by
  `{path, line, field, value}`, equals the index's `known_anomalies:` set exactly. A new
  violation fails (drift detected); a missing one fails (a past entry was silently normalized
  or deleted — the very act the append-only rule forbids). **Additionally (ISS-0193, §13.6):**
  every declared record's `path:` must name a volume that is `status: closed` and carries a
  `frozen_prefix_sha256:`, **and** that volume must independently pass the new **A10**
  warranted-closure check (§13.12.4).
- **A6 — Closed volumes are frozen.** For each closed volume, SHA-256 over its first
  `frozen_prefix_lines` lines (CRLF normalized to LF, so the digest is platform-stable)
  equals `frozen_prefix_sha256`. Volume 1's entire history is covered; the closure footer
  sits beyond the prefix so it can be written once and the digest still pins every entry.
- **A7 — Volume chain integrity.** Every closed volume's footer names its successor's path,
  and that path is the next volume in the index.
- **A8 — Header completeness, including the ceilings.** The current volume's header names all
  six legal `event` values and both legal `req` values. A future volume opened by copy-paste
  error, or a vocabulary extension that skips the header, is caught. **A8 additionally
  asserts that the two ceiling numbers quoted in the current volume's header text
  (`under 1,200 lines / 120,000 bytes` in HOW-TO-APPEND step 2, and
  `lines > 1200 OR bytes > 120000` in the roll rule) equal `roll_rule.max_lines` and
  `roll_rule.max_bytes` from the index, and that `StatusHistory.default_ceilings()` returns
  the same pair.** This is the answer to a restatement hazard the
  design otherwise carries: the ceilings appear in five places — the index `roll_rule`, every
  volume header, the `core-directives.md:328` replacement (§10.3), the `doc-updater.md:31`
  replacement (§10.2) and the `anti-patterns.md` replacement (§10.5) — and the index is the
  single source of truth. A8 pins the volume header, which is the copy an appending agent
  actually reads. **The three prose copies in §10.2/10.3/10.5 are deliberately written to
  point at the index rather than restate the numbers** (see those sections' text), so after
  this design there are exactly three machine-checked copies — the index `roll_rule`, the
  current volume's header, and `StatusHistory.default_ceilings()` — and no unchecked prose
  copy.
- **A9 — `entries:` is checked against disk, not merely declared (added 2026-08-21,
  ISS-0199).** For every volume in `volumes:`, its declared `entries:` count equals
  `length(StatusHistory.entries(path))` — the real count on disk. HOW-TO-APPEND step 6
  and the roll rule's step 3 are what keep the declared count current; A9 is what catches
  it going stale if either is skipped. Found live: volume 2 sat at declared `entries: 0`
  with 7 real entries already appended, because nothing before A9 compared the two.
- **A10 — A closed volume's closure was warranted (added 2026-08-21, ISS-0193; §13.12.4 is
  normative).** For every volume whose `status:` is `closed`, its recorded `lines:` and
  `bytes_working_tree:` (the index's own snapshot, not a live re-measurement — see §13.12.4
  for why) exceed `roll_rule.max_lines` or `roll_rule.max_bytes` respectively. This is the
  shared instrument A4b's and A5's closed-and-pinned rules both depend on, so that "closed and
  pinned" cannot be satisfied by a volume that was rolled early, in the same commit that
  declares an anomaly against it, purely to launder a fresh violation into a permanently
  declared one (CODE-DESIGN-VALIDATOR's MINOR-4 at ISS-0119's own Step 4e re-gate).

**Scope note for TEST-DESIGNER:** A0, A3 and A6 are the three that matter most — **A3 is
both the live guard and the fail-first proof for ISS-0119** (§7.1), A0 is what stops A3's
degraded resolution from ever being reached silently, and A6 is the enforcement of the
append-only rule that has, until now, had no enforcement mechanism at all. A3b is a
detector-calibration guard and is explicitly **not** the fail-first proof.

### 7.1 The fail-first demonstration — A3 fails on the pre-fix commit

WF-03 Step 4 requires a test **shown** to fail against the pre-fix state and pass against
the post-fix state: *"checked out the pre-fix commit, ran the new test, confirms it failed;
then confirms it passes on the fix branch."* That obligation is mandatory and this design
does not declare it satisfied without being performed. The procedure below is **required**,
not optional, and TEST-DESIGNER must quote its actual output in the test spec.

**The obstacle, stated first because it is real.** A *naive* checkout of `3d19e8c` cannot
demonstrate anything on its own: every assertion in §7 is derived from
`docs/status/requirement_status.index.yaml`, which does not exist at `3d19e8c` or at any
pre-fix commit. A test that simply reads the index there errors on a *missing file* — a
failure any test of any new file produces, which proves nothing about coverage of this bug.

**The design decision that removes the obstacle: current-volume resolution degrades.**
`StatusHistory.current_volume/2` (§7) returns `{:index, path}` when the index exists and
`{:no_index_fallback, "docs/status/requirement_status.yaml"}` when it does not — because
that single file *was* the entire status history before this fix, so it is the correct
answer to "which volume is current?" in the pre-index world. Bounds degrade with it:
`default_ceilings()` when there is no index to read `roll_rule` from.

**Consequence — A3 becomes directional, with no change to what it asserts:**

| tree | `current_volume/2` resolves to | measured | A3 (`within_bounds? == :ok`) |
|---|---|---|---|
| pre-fix (`3d19e8c`) | `requirement_status.yaml` (fallback) | 4,217 lines / 260,644 bytes in the blob | **FAILS** — over both ceilings |
| post-fix (fix branch) | `requirement_status.v2.yaml` (index) | far under both | **PASSES** |

One artefact, one assertion, two different verdicts in the two states, and the pre-fix
failure is a *size* failure — exactly the defect ISS-0119 reports — not a missing-file
error. That is the property WF-03 Step 4 asks for, met literally.

**The required Step 4 procedure.** Run it in a throwaway git worktree so the fix branch is
never disturbed. `test/support` is on the `:test` load path at `3d19e8c` — verified: that
commit's `mix.exs:20` already reads `defp elixirc_paths(:test), do: ["lib", "test/support"]`
— so the two new files compile there without any build-config change.

```bash
git worktree add /tmp/iss0119-prefix 3d19e8c
cp test/support/status_history.ex /tmp/iss0119-prefix/test/support/
mkdir -p /tmp/iss0119-prefix/test/docs
cp test/docs/requirement_status_invariants_test.exs /tmp/iss0119-prefix/test/docs/
cd /tmp/iss0119-prefix ; mix deps.get ; mix test test/docs/requirement_status_invariants_test.exs
```
```powershell
git worktree add $env:TEMP/iss0119-prefix 3d19e8c
Copy-Item test/support/status_history.ex $env:TEMP/iss0119-prefix/test/support/
New-Item -ItemType Directory -Force $env:TEMP/iss0119-prefix/test/docs | Out-Null
Copy-Item test/docs/requirement_status_invariants_test.exs $env:TEMP/iss0119-prefix/test/docs/
Set-Location $env:TEMP/iss0119-prefix ; mix deps.get ; mix test test/docs/requirement_status_invariants_test.exs
```

**What TEST-DESIGNER must quote in the test spec** — all four, verbatim, no paraphrase:

1. The pre-fix run's **A3 failure**, showing it failed on `over: [:lines, :bytes]` at
   ~4,217 lines / ~260,644 bytes against the ceilings, i.e. on *size*.
2. That A3's pre-fix resolution was `{:no_index_fallback, "docs/status/requirement_status.yaml"}`,
   proving the failure came from measuring the pre-fix current volume and not from a
   missing index. (A0 is *expected* to fail in the same pre-fix run, for exactly that
   reason; say so, so a reader is not misled by two red assertions.)
3. The same test passing on the fix branch, A3 and A0 both green.
4. The worktree teardown (`git worktree remove ...`), so nothing is left behind.

**Cleanup is part of the procedure**, not an afterthought: a stale worktree at a pre-fix
commit is itself a trap for a later agent.

**THE TRAP THIS FALLBACK MUST NOT BECOME, and how it is closed.** A degraded resolution
that silently answers "volume 1" is a route by which a future agent could append to a frozen
volume. Four independent barriers, each sufficient alone:

1. **It is test-only code.** `Letflow.Test.StatusHistory` lives in `test/support/` and
   compiles only under `MIX_ENV=test` (`mix.exs:20`). It is unreachable from `lib/`, from
   any mix task, and from any agent procedure.
2. **No instruction file mentions it.** The append target is resolved *exclusively* by §4's
   HOW-TO-APPEND step 1, reading `status: current` from the index — and that procedure has
   **no fallback by design**: §4 step 1 and §10.3 both say that if the index cannot be read,
   STOP and file a defect. An agent never consults `current_volume/2`.
3. **A0 makes the degraded path loudly unreachable post-fix.** On any tree that has the fix,
   the index exists; if it is ever deleted or renamed, A0 fails before A3 is even
   interesting. The fallback can never be *silently* active.
4. **The tag makes it impossible to consume by accident.** `current_volume/2` returns
   `{:no_index_fallback, path}`, not a bare path. A caller must destructure the degraded tag
   deliberately; A3 asserts on whichever it got, A0 asserts it got `{:index, _}`.

**A3b — DETECTOR-CALIBRATION GUARD (kept, and honestly labelled).**
  `StatusHistory.within_bounds?("docs/status/requirement_status.yaml", roll_rule.max_lines, roll_rule.max_bytes)`
  returns `{:error, %{over: [:lines, :bytes]}}` at 5,766 lines / 361,376 working-tree bytes
  (355,610 in the blob — the assertion checks `> max_bytes`, not an exact value, so it is
  checkout-independent).

  **This is NOT the fail-first proof and must not be described as one.** Volume 1 is over
  both ceilings *before* the fix and *after* it, so A3b is green in both worlds and is never
  shown to fail; and under this design that file is frozen, pinned by A6, no longer the
  append target, and *expected* to be oversized — so asserting it is oversized restates the
  freeze rather than testing a regression. What A3b genuinely buys, and why it is kept: it
  proves `within_bounds?/3` actually fires at the index's real ceilings against a real
  361 KB artefact, so it fails if the helper's line or byte measurement regresses, or if a
  future agent raises the ceilings toward the tool limits (which §12 #2 forbids). That is a
  calibration guard on the detector, and it is worth having next to A3 — it is simply not
  the thing that satisfies Step 4.

**Rejected alternatives, recorded so they are not re-proposed:** a checked-in oversized
fixture under `test/fixtures/` — it would have to be ≥120,000 bytes to trip the ceiling, and a
*synthetic* file that large proves the arithmetic, not the regression; and a setup-time
`git show` into a temp file as the *primary* mechanism — it makes the suite fail on a shallow
clone for a reason unrelated to the invariant.

A third route was considered and rejected on this pass: **a mandatory one-off
`git show 3d19e8c:docs/status/requirement_status.yaml` extraction, exercising
`within_bounds?/3` against the extracted file via `mix run`, quoted into the Step 4 record.**
It is workable, and it removes the fallback path entirely. It was rejected because it does
not meet Step 4's words as literally as the degraded-resolution route does: what fails there
is a *helper call on an extracted blob*, not "the new test" run against "the pre-fix commit",
so the two-verdict pair would be demonstrated beside the test rather than by it — and the
demonstration would be a one-time transcript rather than a property of the assertion. The
degraded-resolution route makes fail-first intrinsic to A3, at the cost of one fallback that
this section closes with four independent barriers.

---

## 8. No-entry-dropped method, and how it is verified

**Method:** there is no data-moving step. All 182 entries stay in the file they are already
in, at the line numbers they already occupy. The only write to volume 1 is an append of
comment lines at EOF. This is the strongest available guarantee: nothing can be dropped by
a partition rule that is never executed.

**Verification, run by ELIXIR-DEV at Step 3 and quoted in its handoff (no speculation).**
Each check is given for both shells, for the same reason §4 is (`grep`/`sed`/`wc` do not
exist in PowerShell). `SF` below is `docs/status/requirement_status.yaml`.

1. Deletions must be **0**. Any nonzero value means a line above EOF changed; revert.
   Both shells: `git diff --numstat docs/status/requirement_status.yaml`
2. Entry count must still be **182**.
   - Bash: `grep -c '^  - req: ' $SF`
   - PowerShell: `(Select-String -Path $SF -Pattern '^  - req: ').Count`
3. Line 5158 must return the same text it returns before the change (currently:
   `      merge_effective_pins, returning a distinct UnknownPinRef and`), proving
   `iss-0078-pin-rebind-provenance.md:367`'s citation still resolves.
   - Bash: `sed -n '5158p' $SF`
   - PowerShell: `(Get-Content $SF)[5157]`
4. The three anomalies must still be present and still wrong — three
   `    event: SCOPE-CHANGE` lines, proving they were not normalized.
   - Bash: `sed -n '3490p;3577p;3744p' $SF`
   - PowerShell: `(Get-Content $SF)[3489,3576,3743]`
5. Compute `frozen_prefix_sha256` (definition below), write it into the index, and confirm
   `mix test test/docs/requirement_status_invariants_test.exs` passes (A6 green).
6. `git diff --numstat` over the whole commit → the only files with a nonzero deletions
   count may be the instruction sites from §10; `docs/status/requirement_status.yaml` must
   show insertions only.

**`frozen_prefix_sha256` — the exact byte stream that is hashed.** The digest's whole job is
to be reproducible by a later agent on a different host, so the convention is fixed here and
must be implemented exactly as stated in both `test/support/` and the Step 3 computation:

> Take the first `frozen_prefix_lines` lines of the volume. Strip every line's terminator
> (`\r\n` or `\n`) and re-join with a single `\n` **after every line, including the last** —
> i.e. the hashed stream is `Enum.map_join(lines, "", &(&1 <> "\n"))`, which ends in `\n`,
> **not** `Enum.join(lines, "\n")`, which does not. The two differ by one byte and yield
> different digests. Encoding is the file's bytes as-is (UTF-8, no BOM handling, no
> whitespace trimming beyond the line terminator).

Reference implementations, all of which must agree:

- Elixir (the test) — **corrected; see the §8 ERRATUM below**:
  `File.stream!(path) |> Enum.take(n) |> Enum.map_join("", &((&1 |> String.trim_trailing("\n") |> String.trim_trailing("\r")) <> "\n")) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)`
- Bash: `head -n 5766 $SF | tr -d '\r' | sha256sum`
- PowerShell: build the stream, write it with no extra terminator, then hash the temp file.
  Given as a fenced block, not inline, because the command contains PowerShell's backtick
  newline escape and markdown would truncate an inline span at it:

  ```powershell
  $s = (Get-Content $SF -TotalCount 5766 | ForEach-Object { $_ + "`n" }) -join ''
  [IO.File]::WriteAllText($tmp, $s, [Text.UTF8Encoding]::new($false))
  Get-FileHash $tmp -Algorithm SHA256
  ```

  Note `Get-Content` already strips the CR of a CRLF pair itself, so no separate
  CRLF-normalisation step is needed here.

**The Bash form is normative** — `head` emits a terminator after every line it prints,
including the last, which is exactly the convention above, so it is the shortest correct
expression of it. The Elixir and PowerShell forms must reproduce its digest; ELIXIR-DEV
quotes both the `sha256sum` output and the value the test computes at Step 3, and they must
match. (If they do not, the defect is in the implementation, not in this convention.)

> **§8 ERRATUM — ruled at Step 3d by REVIEWER, applied at Step 4 by TEST-DESIGNER.**
>
> As originally written, this section's three reference implementations did **not** agree,
> and the sentence introducing them ("all of which must agree") asserted a property that
> did not hold. ELIXIR-DEV found the disagreement at Step 3 and REVIEWER reproduced it
> independently at Step 3d.
>
> - Bash (normative) and PowerShell both yield
>   `5a1a64ab0b999da3fd86be90109ecee46b9d538d9e9945c0d39fddb10075a804` (355,610 bytes
>   hashed).
> - The **original** Elixir form — `String.trim_trailing(&1, "\r\n")` — yielded
>   `5c9fda42d72b0d46e4bf60cfc5a0fc044d7c36eb0192bc4b5e599c2a559b657a` (361,376 bytes
>   hashed): exactly +5,766, one extra byte per line.
>
> **Cause.** `File.stream!/1` opens the file in **text mode**. On a CRLF checkout it has
> already stripped the CR by the time the line reaches the mapper, so a trim of the literal
> two-byte suffix `"\r\n"` matches nothing; the surviving `\n` stays, and `<> "\n"` appends a
> second. REVIEWER confirmed the mechanism directly: `File.stream!` yields line 1 as
> `"# RoCo — Requirement run history\n"` — a bare `\n`.
>
> **The correction**, now in place in the Elixir bullet above and in
> `test/support/status_history.ex`: trim `"\n"` **first**, then `"\r"`, and never the literal
> two-byte `"\r\n"`. **That order is load-bearing.** It is what makes the form correct both
> for a CRLF text-mode read and for an LF/binary read — i.e. portable to CI, where the
> checkout is LF. The convention stated above this erratum is unchanged; only the Elixir
> expression of it was wrong.
>
> **Discharged.** §8's CHECK 5 was not dischargeable at Step 3 because the test did not yet
> exist, and ELIXIR-DEV correctly declined to claim it. At Step 4 the corrected Elixir form,
> as implemented in `Letflow.Test.StatusHistory.frozen_prefix_digest/2` and exercised by
> assertion A6, computes
> `5a1a64ab0b999da3fd86be90109ecee46b9d538d9e9945c0d39fddb10075a804` — **equal** to the
> normative Bash value and to the `frozen_prefix_sha256` recorded in the index. All three
> forms now agree. Evidence: `test/specs/ISS-0119.md`.
>
> This erratum is recorded here, inline in the artefact, rather than only in a handoff —
> because "a correction recorded where nobody lands" is the failure class ISS-0119 is
> itself about.

**Old-citation resolution:** none is needed, and that is the point of freeze-and-roll.
`docs/status/requirement_status.yaml` still exists, still holds the same content, still has
the same line numbers. The ~103 historical references under `handoffs/` and `test/reports/`
resolve unchanged; `TASK_QUEUE.md:379`'s "see requirement_status.yaml's SCOPE-CHANGE entry"
still finds it in volume 1; `iss-0078-...:367`'s `:5158` still resolves. No retro-edit of any
immutable artefact is required or permitted. C4 is satisfied by construction.

---

## 9. Closing the `core-directives.md:173` vs `:328` precedence gap

**The ruling: the scoped-read rule (`:173`) is the general rule and it governs everything,
including every CLOSED volume. The full-read requirement survives only for the CURRENT
volume, and it survives only because the roll rule bounds that volume to stay executable.**

Rationale, in the diagnosis's own terms: "the conflict was already resolved in favour of
the full read, the winning branch has become unavailable, and nothing anywhere states the
fallback." This design does not re-litigate the resolution — a full read of the file you are
about to append to is correct, because it is the only thing that shows you the schema. It
makes that branch *available again* by capping the file, and then states the fallback that
was missing: closed volumes are never appended to, therefore never need a full read,
therefore fall under `:173` like every other large file.

**Where the ruling is written down — three sites, so an agent hits it from any direction:**

1. **`core-directives.md:328` (§Bookkeeping item 3)** — the primary statement (text in
   §10.3). It states the ruling *and* forward-references `:173`.
2. **`core-directives.md:173` (§Load Scoped Context)** — a back-reference appended to that
   paragraph, so an agent reading the general rule learns of the one exception rather than
   applying the general rule to the current volume and appending from a fragment.
3. **The index file's header** — the entry point every instruction site now points at.

---

## 10. The 23 instruction sites — required action for each

Numbering follows the diagnosis §3(ii). "EDIT" sites are wrong or ambiguous after the change
and must be updated in the Step 3 commit; "NO CHANGE" sites remain true because volume 1's
path still exists and still means what it meant.

### 10.1 Summary table

**Count, stated so Step 3 can check itself against it:** 23 numbered sites = **15 EDIT + 8 NO
CHANGE**. The table has 24 rows: the 24th is the unnumbered `core-directives.md:173`
back-reference, which this design *adds* on top of the diagnosis's enumeration, giving **16
EDIT rows over 24 rows**. (An earlier summary of this design said "14 EDIT + 9 NO CHANGE";
that figure was wrong and is corrected here — the table itself was and is complete.)

| # | Site | Action |
|---|---|---|
| 1 | `CLAUDE.md:85` | **EDIT** — point at the index, not the file |
| 2 | `core-directives.md:290` (artifact table) | **EDIT** — retitle the row |
| 3 | `core-directives.md:328` (append-only rule) | **EDIT** — the precedence ruling (§10.3) |
| — | `core-directives.md:173` (scoped-read rule) | **EDIT** — back-reference to item 3 (§10.3) |
| 4 | `core-directives.md:354` (YAML format rule) | NO CHANGE — cites the file as a format exemplar; still valid |
| 5 | `doc-updater.md:17` (mandatory reading, "in full") | **EDIT** — §10.2 |
| 6 | `doc-updater.md:23` (anti-patterns pointer) | NO CHANGE — the anti-pattern entry survives with new text |
| 7 | `doc-updater.md:31` ("What you do" step 2) | **EDIT** — §10.2 |
| 8 | `doc-updater.md:47` (Forbidden) | **EDIT** — extend the prohibition to every volume |
| 9 | `release-validator.md:23` (reading list) | **EDIT** — read the index, then targeted lookups |
| 10 | `release-validator.md:32` | NO CHANGE — prose about not trusting the history's narration |
| 11 | `AGENT_SYSTEM.md:46` (DOC-UPDATER owned artifacts) | **EDIT** — say `docs/status/requirement_status*.yaml` (all volumes + index) |
| 12 | `AGENT_SYSTEM.md:105` ("remains the append-only event history (started/done/blocked)") | **EDIT** — the parenthetical is now wrong twice over |
| 13 | `AGENT_SYSTEM.md:136` (artifact/owner/format row) | **EDIT** — same widening as #11 |
| 14 | `ORCHESTRATOR.md:129` (escalations.yaml "same convention as…") | NO CHANGE — analogy to append-only spirit, still true |
| 15 | `WF-01:59` ("same append-only spirit as…") | NO CHANGE — same |
| 16 | `WF-02:106` (append a `started` event) | **EDIT** — via the index |
| 17 | `WF-02:377` (staleness check) | NO CHANGE — reads history, does not append |
| 18 | `WF-02:390` (append a `done` event) | **EDIT** — via the index |
| 19 | `WF-04:66` | NO CHANGE — prose, same as #10 |
| 20 | `ISSUE_QUEUE.md:156` ("same append/never-rewrite spirit") | NO CHANGE — analogy |
| 21 | `TASK_QUEUE.md:133` (**wrong field**) | **EDIT** — §10.4 |
| 22 | `TASK_QUEUE.md:379` (look up the mapping) | **EDIT** — §10.4 |
| 23 | `anti-patterns.md:68-83` (the anti-pattern entry) | **EDIT** — §10.5 |

Prose-only referrers (diagnosis §3(i), items 24–30) need no edit: volume 1's path and line
numbers are unchanged, which is precisely why freeze-in-place was chosen. In particular
`lib/letflow/design/iss-0078-pin-rebind-provenance.md:367`'s `:5158` citation stays valid
and **must not be edited** — verified by §8 check 3.

`docs/requirements.yaml:444` ("a written note in this requirement's requirement_status.yaml
entry") is left as-is: it obliges a future run to write *an entry*, which the index resolves
to the then-current volume. No edit needed.

### 10.2 `.claude/agents/doc-updater.md`

Line 17's bullet is replaced by:

> - `docs/status/requirement_status.index.yaml`, then **the current volume it names, in
>   full** — you append to that volume and must match its schema exactly, and the volume
>   is bounded — see `roll_rule:` in the index for the current ceilings — specifically so a
>   full read is possible. Closed volumes are
>   frozen: read them only with a targeted read — the Read tool with `offset`/`limit`, or
>   `grep`/`sed` on Bash, or `Select-String` on PowerShell — never in full. See
>   `core-directives.md` §"Bookkeeping Is Not Optional" item 3 for why this file is the one
>   exception to "Load Scoped Context, Not Whole Files".

Line 31's step 2 is replaced by:

> 2. Append one event to the **current** run-history volume — find it in
>    `docs/status/requirement_status.index.yaml`, never by assuming a filename. Follow the
>    "HOW TO APPEND" procedure in that volume's own header: read the volume in full, take
>    the timestamp from the clock, append (never rewrite), then confirm with
>    `git diff --numstat` that the deletions count is 0. Then apply the header's roll rule:
>    if the volume is now over the `roll_rule:` ceilings recorded in the index, close it and
>    open the next one in this same commit. Read the ceilings from the index; do not carry a
>    remembered number.

Line 47's Forbidden paragraph gains:

> This applies to **every** volume, closed or current. Never edit, reorder, renumber or
> "clean up" an entry in a closed volume — including the three known-anomalous
> `event: SCOPE-CHANGE` entries declared in the index. They are wrong on purpose; correcting
> them is the rewrite this rule exists to prevent, and
> `test/docs/requirement_status_invariants_test.exs` will fail if you do.

### 10.3 `docs/agents/instructions/core-directives.md`

Item 3 of §"Bookkeeping Is Not Optional" (`:328`) is replaced by:

> **3. The requirement run history is append-only, and it is kept in bounded volumes.**
> Start at `docs/status/requirement_status.index.yaml`; it names the current volume. Read
> **that volume in full** before appending, preserve its schema, append — never rewrite,
> reorder or delete an entry, in any volume. An agent has gotten this wrong before (see
> `docs/anti-patterns.md`).
>
> **Precedence, so this is not ambiguous:** "Load Scoped Context, Not Whole Files" above is
> the general rule and it governs *closed* volumes and every other large file — read those
> with a targeted read only: the Read tool with `offset`/`limit`, or `grep`/`sed`/`awk` under
> Bash, or `Select-String`/`Get-Content -TotalCount` under PowerShell (this repo runs both
> shells and `grep` does not exist in PowerShell — see the pairs at `:156-161` above). The
> **current** volume is the single exception, and it is an
> exception only because the roll rule (`roll_rule:` in the index — that file holds the
> authoritative ceilings) keeps it small enough that the full read is actually executable.
> If a full read of the current volume is ever refused or
> truncated, that is a defect in the roll rule: stop and file it (ISS-0119 is the precedent),
> do not substitute a partial read and append anyway.

The paragraph at `:173` gains a final sentence:

> The one deliberate exception is the **current** requirement-status volume, which you must
> read in full before appending to it — and which is deliberately kept small enough that you
> can. See §"Bookkeeping Is Not Optional" item 3.

### 10.4 `docs/agents/protocols/TASK_QUEUE.md`

Line 133's sentence — the instruction that produced the three malformed entries — is
replaced by:

> Record the reconciliation in the current run-history volume (find it via
> `docs/status/requirement_status.index.yaml`) as an entry with **`req: SCOPE-CHANGE`** and
> a normal `event:` value (usually `done`), naming the reconciliation in `note:`. Note the
> field: `SCOPE-CHANGE` is a **`req`** value, never an `event` value. An earlier version of
> this line said "as a `SCOPE-CHANGE` event" and produced three malformed entries, now
> recorded as known anomalies in the index.

Line 379's clause is replaced by:

> — see `docs/status/requirement_status.yaml`'s (volume 1, closed) entries with
> `req: SCOPE-CHANGE` for the full REQ-ID ↔ queue-task-id mapping.

### 10.5 `docs/anti-patterns.md`

The existing entry's narrative is **kept** (it is the record of what happened). Its
"Correct alternative" paragraph is replaced by:

> **Correct alternative:** start at `docs/status/requirement_status.index.yaml`, read the
> **current volume** it names in full — volumes are capped, at the ceilings the index's
> `roll_rule:` records, precisely so that read is possible — preserve its established schema
> even if a different
> shape seems cleaner, and append (never replace). Confirm with `git diff --numstat` that
> the deletions count for the file is 0. Never edit a closed volume. If the file is
> genuinely missing, use the header/entry shape documented in the index and the current
> volume's own header, not an invented one.

A short new entry is appended to the same file:

> ## An instruction whose mechanism has silently become unexecutable
>
> `docs/status/requirement_status.yaml` grew past the Read tool's 256KB limit on
> 2026-08-18. For ~2.5 days every agent was instructed to "read the file in full before
> appending" while that read returned a hard refusal, and no written rule said what to do
> instead — so each agent improvised a different partial read, and the safeguard read as
> followed while being unexecutable. The prior drift (three entries putting `SCOPE-CHANGE`
> in the `event` field) proves the same point from the other side: it happened while the
> file was still readable, because "read it all" was never a reliable way to transmit a
> convention buried in one of 182 entries.
>
> **Correct alternative:** when a safeguard's mechanism has a physical limit, bound the
> thing so the mechanism keeps working, state the convention explicitly instead of leaving
> it to be inferred from precedent, and add a mechanical check that fails when the bound is
> next crossed. A rule enforced only by an agent's eyes has no second line of defence. See
> ISS-0119 and `lib/letflow/design/iss-0119-status-file-readability.md`.

### 10.6 Remaining EDIT sites (mechanical)

- `CLAUDE.md:85` → "append one event to the current run-history volume (find it via
  `docs/status/requirement_status.index.yaml`) — started/done/blocked/cancelled/revised/
  verified, with a real UTC timestamp from the clock, not memory."
- `core-directives.md:290` table row → `| Requirement status history | docs/status/requirement_status.index.yaml (names the current volume) |`
- `release-validator.md:23` → "`docs/status/requirement_status.index.yaml` and, for any
  entry you need, a targeted read of the volume it lives in — do not read closed volumes in
  full."
- `AGENT_SYSTEM.md:46` and `:136` → widen the owned-artifact/format cells to
  `docs/status/requirement_status*.yaml` (index + all volumes), owner `DOC-UPDATER`.
- `AGENT_SYSTEM.md:105` → "remains the append-only event history (`started`/`done`/
  `blocked`/`cancelled`/`revised`/`verified`), kept in bounded volumes behind
  `docs/status/requirement_status.index.yaml`."
- `WF-02:106` and `:390` → "append a `started`/`done` event to the current run-history
  volume (via `docs/status/requirement_status.index.yaml`) — append, do not rewrite prior
  entries."

---

## 11. Complete list of files ELIXIR-DEV changes at Step 3

**Created (4):** `docs/status/requirement_status.v2.yaml`,
`docs/status/requirement_status.index.yaml`,
`test/support/status_history.ex` (the path-parameterised helper module, §7),
`test/docs/requirement_status_invariants_test.exs` (Step 4 may own both test files instead, at
ORCH's routing discretion; the design specifies them either way).

**Modified — 9 distinct files** (the per-site breakdown is §10.1's table; count files here,
sites there): `docs/status/requirement_status.yaml` (EOF footer append only),
`CLAUDE.md`, `docs/agents/instructions/core-directives.md` (3 sites: `:173`, `:290`, `:328`),
`.claude/agents/doc-updater.md` (3 sites), `.claude/agents/release-validator.md` (1 site),
`docs/agents/AGENT_SYSTEM.md` (3 sites), `docs/agents/workflows/WF-02_requirement_implementation.md` (2 sites),
`docs/agents/protocols/TASK_QUEUE.md` (2 sites), `docs/anti-patterns.md` (1 rewrite + 1 new entry).

**Explicitly NOT modified:** any file under `handoffs/` or `test/reports/` (immutable run
records); `lib/letflow/design/iss-0078-pin-rebind-provenance.md` (its `:5158` citation must
keep resolving); volume 1 lines 1–5,766; the three anomalous entries.

---

## 12. Open questions for ORCH / ELIXIR-DEV

None blocks Step 3. Recorded rather than silently decided:

1. **Volume naming.** `requirement_status.v2.yaml` was chosen over a date-based name
   (`requirement_status.2026-08.yaml`) because rolls are triggered by size, not by calendar
   period — a date-named file that rolls mid-month is misleading. If ORCH prefers a
   date-based scheme, only the `path:` values change; nothing else in this design depends
   on the naming, because every consumer goes through the index.
2. **Roll ceilings (1,200 lines / 120,000 bytes).** Chosen for headroom against the Read
   tool's 2,000-line and 262,144-byte limits, at ~40 entries per volume. Loosening them
   trades read cost for roll frequency; they must never be raised to the tool limits
   themselves, since the headroom is what prevents a single append from crossing the cliff.
   The index's `roll_rule:` is the single source of truth for these numbers: A3/A3b read them
   from it, A8 asserts the current volume's header quotes the same two values, and every
   instruction-site replacement in §10.2/10.3/10.5 points at the index instead of restating
   them — so changing a ceiling means editing the index and one volume header, with A8
   failing if the header is missed.
3. **Where the invariant test lives in the gate.** It runs under plain `mix test` (and
   therefore `mix letflow.check`'s test step) with no database. Whether it should *also* be
   a standalone `mix letflow.check` step, so a docs-only change is gated without the full
   suite, is a REVIEWER call, not a design decision.
4. **The 3 anomalies are permanent.** This design deliberately leaves them wrong forever.
   If the project ever wants them annotated, the only append-only-compatible route is a new
   entry in the current volume that references them — never an edit. Not proposed here.

---

## 13. POST-GATE AMENDMENT — 2026-08-21 — three shape anomalies in frozen volume 1

**Status:** amendment. Written 2026-08-21, **after** this artefact passed
CODE-DESIGN-VALIDATOR (re-gate pass 3). Sections 1–12 above are the gated design and are
unchanged except for three cross-reference markers pointing here (§5 preamble, A4, A5).
This section is normative wherever it says so.

**Dispatched as:** `handoffs/WF03-ISS0119-20260821/step-04d-code-designer-amendment.json`
(CODE-DESIGNER, rework_count 0 — new evidence, not rework of the step-02 handoff).

**Re-amendment iteration 1 — 2026-08-21.** CODE-DESIGN-VALIDATOR gated this section at
Step 4e and passed nine of ten checks, failing one at MAJOR: §13.3's bounding claim for
`known_shape_anomalies:` existed only as prose, so a future agent could have declared away a
new shape defect in the *current* volume and left A4b green forever. Three things changed in
response, and nothing else: A4b gained the closed-volume-only rule (§13.5, mirrored into
§13.4's block comment), A4b's failure-message content is now specified (§13.5), and §13.3's
bullet now cites the assertion instead of asserting the property. **The three declared
records in §13.4 are unchanged** — all cite closed, digest-pinned volume 1. §13.11 Q1 is
also now answered on the record. Sections 1–12 were not touched again.

### 13.1 The prompting finding

Assertion **A4** (§7) was implemented and **run for the first time** at Step 4. It went red
on **three volume-1 entries that nobody knew were malformed** — a different defect class from
the three `event: SCOPE-CHANGE` entries §5 already declares, and a different set of entries:

| entry (`- req:` line) | req | event | defect |
|---|---|---|---|
| 4803 | REQ-053 | started | **no `note:` field** (four fields, not five) |
| 4896 | REQ-056 | started | **`timestamp:` written where `at:` belongs** (value at line 4899) |
| 5050 | REQ-054 | started | **no `note:` field** (four fields, not five) |

Corroborated independently by field-count arithmetic over volume 1 before this amendment was
written (Bash, on the fix branch working tree; anchored patterns, entry-body indentation):

```
grep -c '^  - req: '       docs/status/requirement_status.yaml  ->  182
grep -c '^    event: '     docs/status/requirement_status.yaml  ->  182
grep -c '^    agent: '     docs/status/requirement_status.yaml  ->  182
grep -c '^    at: '        docs/status/requirement_status.yaml  ->  181
grep -c '^    note: '      docs/status/requirement_status.yaml  ->  180
grep -n '^    timestamp: ' docs/status/requirement_status.yaml  ->  4899:    timestamp: "2026-08-19T02:40:35Z"
```

182 entries, 181 `at:`, 180 `note:` — one missing `at:` and two missing `note:`, matching the
three named entries exactly and nothing else. (ORCH's dispatch quoted 183/182/181 from
unanchored patterns; the delta is one extra match per pattern outside an entry body. The
*differences* — 1 and 2 — are identical, and the three named entries are the same three.)

**This is real drift, not a broken test.** It is also the strongest evidence this run has
produced: these entries accumulated invisibly for months precisely because no mechanical
check existed, and the very first mechanical check found them immediately. Nothing in this
amendment may reduce that detection.

### 13.2 The two constraints that make this non-trivial

1. **Volume 1 must not be edited.** It is frozen and pinned by A6. "Correcting" a past entry
   is exactly the rewrite the append-only rule exists to forbid (C1/C2). Not now, not ever.
2. **`known_anomalies:` cannot hold these.** It is keyed `{path, line, field, value}` for
   **vocabulary** violations — an entry whose field *value* is not in the documented list —
   and **A5 asserts set equality in both directions**. A missing field has no line and no
   value to cite; a misnamed field's value is perfectly legal. Adding these three to
   `known_anomalies:` would turn **A5 red**, trading one red for another.

TEST-DESIGNER declined to weaken A4 to clear the red, and was right to: a test that only ever
runs against already-correct code proves nothing, and suppressing this would be the silent
drift ISS-0119 exists to stop. That refusal is why this amendment exists.

### 13.3 DECISION: candidate (i) — a separate `known_shape_anomalies:` index key

**Chosen: (i).** A4 is split into **A4a** (vocabulary, unchanged) and **A4b** (shape), and
the shape exceptions are declared in a new, separately-keyed index list that A4b asserts
**exact set equality against, in both directions**, and that A5 ignores entirely.

**Why (i), on the merits:**

- **It does not weaken what A4 detects — it strengthens it.** A4's shape rule keeps applying
  to every volume, closed and current. The three known entries stop producing a red because
  they are *declared*, and any fourth shape defect — new or historical — still fails
  immediately. Bidirectional equality additionally makes a silent "cleanup" of one of the
  three fail, which is protection A4 did not have before this amendment.
- **It is the design's own established pattern, applied to a second defect class:** never
  edit, always declare (§5's four-point handling, and the `known_anomalies:` mechanism it
  produced). A reader who already understands one understands the other. **This bullet was
  written as a forward-looking claim, not yet a fully accurate one: at the time, A4b's
  exception list carried the closed-and-pinned rule below and A5's did not, so the two
  mechanisms were parity in intent only — a fact CODE-DESIGN-VALIDATOR recorded as an
  incidental finding at this same gate (filed as ISS-0193) rather than blocking this section
  on it, since widening an already-gated section's own guarantee is separate design work.
  ISS-0193 closed that gap (§13.6, §13.12): A5 now carries the identical closed-and-pinned
  rule, so as of that fix this sentence reads as settled fact rather than aspiration, and no
  further rewording is needed here.**
- **The exception list is bounded and permanent, not a growing suppression list — and that
  is asserted, not merely argued.** Volume 1 is frozen and digest-pinned, so its shape
  defects are a closed, finite set that can never grow. Volumes 2 onward are checked live
  from their first entry, so a defect there must be *fixed in the working tree while the
  volume is still current and appendable* — it can never be declared away. **That second
  half is enforced by A4b's closed-volume-only rule (§13.5): a `known_shape_anomalies:`
  record may only cite a volume whose index entry is `status: closed` with a
  `frozen_prefix_sha256:`, so declaring a defect in the *current* volume fails A4b outright.**
  Without that rule this bullet would rest on an agent's judgement — a new defect could be
  appended to the current volume and silenced by adding a matching record, with set equality
  still green. The rule is what makes "bounded by construction" a machine-checked fact.
  Declaring history is not the same as tolerating drift.
- **It keeps the three entries in the file a reader actually opens first.** The index
  declares itself "THE ENTRY POINT"; every appending agent reads it (HOW-TO-APPEND step 1).

**Why (ii) — scope A4's shape check to the current volume only — was rejected:**

- It removes detection rather than declaring exceptions. Every historical shape defect,
  including any *not yet found*, becomes permanently invisible. A4b's set-equality run is
  the only thing that has ever enumerated these; narrowing it to the current volume retires
  that enumeration after a single use.
- It defeats itself at roll time. A volume is checked while current and then frozen. Under
  (ii) a defect appended into volume 2 late in its life is checked only until the roll, after
  which it silently leaves the checked set — permanently. Under (i) it stays checked forever
  and must be either fixed while current or explicitly declared at closure.
- Its premise — "a frozen volume's shape is history and cannot be fixed, so asserting over it
  yields a permanent red or a permanent exception list" — is correct on the facts and wrong
  on the conclusion. **A permanent, declared, machine-checked exception list is the desired
  outcome**, not a cost to be avoided. That is precisely what `known_anomalies:` already is
  for vocabulary, and it has been uncontroversial.
- It fails the run's binding constraint most directly: with the shape check off the frozen
  volume, the three entries have no mechanical reason to be mentioned anywhere, and
  "don't check the frozen thing" becomes "don't check" by attrition.

**No third option was needed.** One sub-option *was* considered and rejected: also appending
these three to **volume 1's closure footer**, mirroring §5's "declared three times over". It
is technically legal — the footer sits beyond `frozen_prefix_lines: 5766`, so the digest
would still hold — but it requires writing bytes into the frozen volume file a second time,
after this run has already closed it, for redundancy the index and the volume-2 header
already provide. Rejected on the conservative reading of "not one byte of volume 1".
**Volume 1 is not modified by this amendment in any way.**

### 13.4 Exact index content to add — verbatim

Append the following block to `docs/status/requirement_status.index.yaml`, **after** the
existing `known_anomalies:` block, at top level (column 0 for the key). Nothing above it in
that file changes — not `roll_rule:`, not `volumes:`, not `known_anomalies:`.

```yaml
known_shape_anomalies:
  # Entries whose FIELD SET or FIELD NAMES do not conform to the five-field entry
  # shape documented in the current volume's header, and which are LEFT AS
  # WRITTEN for the same reason as `known_anomalies:` above: correcting a past
  # entry is precisely what the append-only rule forbids.
  #
  # This is a SEPARATE key from `known_anomalies:` deliberately. That key declares
  # VOCABULARY violations -- an entry that HAS a field whose VALUE is not in the
  # documented list -- and is keyed {path, line, field, value}. It cannot express
  # these: a MISSING field has no line and no value to cite, and a MISNAMED
  # field's value is perfectly legal. Assertion A5 asserts set equality over
  # vocabulary violations in BOTH directions, so filing a shape defect under
  # `known_anomalies:` would turn A5 red. The two sets are disjoint by
  # construction and are asserted separately: A5 over `known_anomalies:`,
  # A4b over `known_shape_anomalies:`.
  #
  # `entry_line` is the entry's own `- req:` line. It is a stable address because
  # volume 1 is frozen and pinned by `frozen_prefix_sha256` above.
  #
  # A RECORD MAY ONLY CITE A CLOSED, DIGEST-PINNED VOLUME. `path:` must name a
  # volume whose `volumes:` entry above has `status: closed` AND a
  # `frozen_prefix_sha256:`. A4b asserts this. A shape defect in the CURRENT
  # volume must be FIXED in the working tree before it is committed -- it can
  # never be declared here. This is what keeps the list bounded: a closed
  # volume's defect set can never grow, so this list can never grow either
  # except when a volume is closed with a defect already in it.
  #
  # `kind:` is one of: missing_field | misnamed_field | extra_field | field_order.
  # Only the first two occur today. A `misnamed_field` record accounts for BOTH
  # the absence of `field:` AND the presence of `found_as:` -- it is ONE
  # violation, not two.
  #
  # Assertion A4b asserts this list equals the shape violations actually on disk
  # EXACTLY, in both directions: a new shape defect fails (drift detected), and a
  # silent "correction" of one of these fails too (a past entry was rewritten).
  # These three were found by A4 on its first ever run, 2026-08-21, under
  # ISS-0119. They had been on disk, undetected, since 2026-08-19.
  - path: docs/status/requirement_status.yaml
    entry_line: 4803
    req: REQ-053
    event: started
    kind: missing_field
    field: note
    found_as: null
    found_line: null
    should_have_been: "note: <short free-text>, as the fifth and last field"
    cause: >
      Appended with four fields instead of five. No mechanical check on entry
      shape existed at the time -- ISS-0119's assertion A4 is the first one, and
      it found this on its first run.
  - path: docs/status/requirement_status.yaml
    entry_line: 4896
    req: REQ-056
    event: started
    kind: misnamed_field
    field: at
    found_as: timestamp
    found_line: 4899
    should_have_been: 'at: "2026-08-19T02:40:35Z"'
    cause: >
      The timestamp field was written as `timestamp:` instead of `at:`. The VALUE
      is correct and is valid ISO-8601; only the field NAME is wrong. `at:` is
      the documented name and is used by the other 181 entries in this volume.
  - path: docs/status/requirement_status.yaml
    entry_line: 5050
    req: REQ-054
    event: started
    kind: missing_field
    field: note
    found_as: null
    found_line: null
    should_have_been: "note: <short free-text>, as the fifth and last field"
    cause: >
      Same as line 4803: appended with four fields instead of five, in the same
      period and by the same appending pattern.
```

**Nothing else in the index changes.** Explicitly: `frozen_prefix_lines: 5766`,
`frozen_prefix_sha256: "5a1a64ab0b999da3fd86be90109ecee46b9d538d9e9945c0d39fddb10075a804"`,
`entries: 182`, `lines: 5766`, `bytes_working_tree: 361376`, `roll_rule:` and all three
existing `known_anomalies:` records are **untouched**.

### 13.5 Exact change to A4 — it splits into A4a and A4b

A4's §7 text is replaced by the following two assertions. Both run across **every** volume in
the index, closed and current — the scope is unchanged.

- **A4a — Vocabulary conformance (unchanged in substance).** Across every volume, every
  `req:` value matches `REQ-\d{3}` or `SCOPE-CHANGE`, and every `event:` value is one of the
  six legal values. Exceptions only as declared in the index's `known_anomalies:`, asserted
  exactly by A5.

- **A4b — Shape conformance, with exceptions declared in `known_shape_anomalies:`.** An entry
  **conforms** when it carries exactly the five fields `req`, `event`, `agent`, `at`, `note`,
  in that order, with a parseable ISO-8601 `at:`. A **shape violation** is one of:
  - `missing_field` — a required field is absent. `field:` = the absent field name;
    `found_as:`/`found_line:` are `null`.
  - `misnamed_field` — a required field is absent **and** an undocumented field carrying its
    value is present in its position. `field:` = the required name, `found_as:` = the name
    actually written, `found_line:` = that line. **One violation, not two** — the detector
    must not also emit a `missing_field` for the same `field:` on the same entry.
  - `extra_field` — a field beyond the five is present. `field:` = its name, `found_line:` =
    its line. (None occur today.)
  - `field_order` — all five present, wrong order. `field:` = the first out-of-order field.
    (None occur today.)

  **A4b asserts: the set of shape violations found on disk equals the index's
  `known_shape_anomalies:` set EXACTLY, in both directions.** A new violation fails (drift
  detected). A missing one fails (a past entry was silently normalized or deleted — the act
  the append-only rule forbids). This mirrors A5 and gives shape the same two-way protection
  vocabulary already has.

  **A4b additionally asserts: every `known_shape_anomalies:` record's `path:` names a volume
  whose `volumes:` entry in the index has `status: closed` AND carries a
  `frozen_prefix_sha256:`.** A record citing the current (open, unpinned) volume, or a path
  that is not a volume in the index at all, fails A4b — **independently of set equality, and
  even when the on-disk violation it cites genuinely exists.** This is the rule that makes
  §13.3's bounding claim mechanical rather than a matter of an agent's judgement: without it,
  a future agent could append a malformed entry to the current volume, add a matching record
  here, and leave A4b permanently green with no gate tripped — satisfying a gate by editing
  what it measures. With it, the only route for a shape defect in the current volume is to
  fix it in the working tree before committing, which is what §13.3 already says happens.
  It changes none of the three records in §13.4: all three cite
  `docs/status/requirement_status.yaml`, which is closed and digest-pinned.

  **Identity key for the comparison:** `{path, entry_line, kind, field, found_as}`. The
  remaining columns are documentation and are not part of the key — but **A4b additionally
  asserts that each declared record's `req:` and `event:` match what is actually on disk at
  `entry_line`**, so a declaration that drifts off its entry fails rather than silently
  matching the wrong row.

  **The ISO-8601 check is not lost for the misnamed entry.** For a `misnamed_field` record
  where `field: at`, A4b parses the value at `found_line:` and asserts it is valid ISO-8601.
  Declaring the field name wrong does not license an unparseable timestamp.

  **A4b's failure output is specified, not left to the implementer.** On any failure — either
  direction of set equality, or the closed-volume rule — the assertion message must name
  **every** element of the symmetric difference, one per line, printing `path`, `entry_line`,
  `req`, `kind` (and `field`/`found_as` where set) for each, labelled by which side it came
  from (`on disk but not declared` / `declared but not on disk`), plus every record that
  failed the closed-volume rule with the volume status that disqualified it. Reporting only a
  count, or only that the sets differ, is not sufficient: §13.9 lists `mix test` as one of the
  four landing points precisely because the three entries are named there, and that claim must
  be guaranteed by this specification rather than by an implementer's choice of message.

  **A4b runs on every volume, permanently.** It is not narrowed to the current volume — see
  §13.3 for why that was rejected.

### 13.6 A5 — unchanged in substance at the original amendment; gains the closed-and-pinned rule under ISS-0193

**As originally written (2026-08-21, this amendment's first pass):** A5 keeps its exact
current text and behaviour: set equality, in both directions, over **vocabulary** violations
keyed `{path, line, field, value}`, against the index's `known_anomalies:`.

- **A5's three declared vocabulary anomalies are unchanged**: lines 3490 (REQ-031), 3577
  (REQ-042), 3744 (REQ-038), all `field: event`, `value: SCOPE-CHANGE`. This amendment adds
  nothing to that list and removes nothing from it.
- **A5 ignores `known_shape_anomalies:` entirely.** It must not read that key.
- **The two sets are disjoint on the actual data, verified:** the three shape-anomalous
  entries carry `req: REQ-053` / `REQ-056` / `REQ-054` and `event: started` — all legal
  vocabulary. They do not appear in A5's on-disk set, so A5's verdict is arithmetically
  unaffected by this amendment.

**FURTHER AMENDED 2026-08-21 — ISS-0193.** The paragraph above is still correct — set
equality and the three records are genuinely untouched — but it was incomplete: it gave A5
no restriction on *which volume* a declared record may cite, unlike A4b above. CODE-DESIGN-
VALIDATOR flagged this as an incidental MAJOR finding at ISS-0119's own Step 4e gate (filed
as ISS-0193 rather than fixed in place, since ISS-0119's design had already cleared its hard
gate and widening it would be scope creep on that pass). Full detail: §13.12.

**A5 additionally asserts** (mirroring A4b's rule in §13.5 verbatim, applied to
`known_anomalies:` in place of `known_shape_anomalies:`): **every `known_anomalies:` record's
`path:` names a volume whose `volumes:` entry in the index has `status: closed` AND carries a
`frozen_prefix_sha256:`.** A record citing the current (open, unpinned) volume, or a path that
is not a volume in the index at all, fails A5 — independently of set equality, and even when
the on-disk violation it cites genuinely exists. This is the rule that makes the "declare,
don't edit" pattern's boundedness mechanical for vocabulary anomalies the same way §13.5 made
it mechanical for shape anomalies: without it, a future agent could append an entry carrying
a new illegal vocabulary value to the current volume, add a matching record to
`known_anomalies:` in the same commit, and leave A5 permanently green with no gate tripped —
satisfying a gate by editing what it measures (`core-directives.md`'s named failure mode).
With it, the only route for a vocabulary violation in the current volume is to fix it in the
working tree before committing.

**A5's closed-and-pinned rule additionally requires the cited volume to pass A10 (§13.12.4).**
Closed-and-pinned alone is not sufficient, per CODE-DESIGN-VALIDATOR's own MINOR-4 finding at
the same gate (quoted in full in ISS-0193's description): a volume can be rolled to `closed`
in the *same* commit that declares a record against it, which would satisfy "closed and
pinned" without ever having been a legitimate roll. A10 closes that route for both A4b and A5
by requiring the cited volume to have actually exceeded `roll_rule` at closure — see §13.12.4
for the shared instrument both rules call into, rather than each re-deriving it.

**It changes none of the three existing `known_anomalies:` records** — verified directly
against the index on disk, not assumed; see §13.12.2 for the exact lines checked.

**A5's failure output is specified, not left to the implementer**, mirroring A4b's
requirement in §13.5: on any failure — either direction of set equality, the closed-and-pinned
rule, or A10 — the assertion message must name **every** element of the symmetric difference,
one per line, printing `path`, `line`, `field`, `value` for each set-equality miss, labelled by
which side it came from (`on disk but not declared` / `declared but not on disk`), plus every
record that failed the closed-and-pinned-and-warranted rule with the specific reason
(not-closed, not-pinned, or not-warranted) and the volume's status/digest/roll-numbers that
disqualified it.

### 13.7 What else does and does not change

- **`frozen_prefix_sha256` DOES NOT CHANGE — stated explicitly, with the reason.** The digest
  covers volume 1's lines 1–5766 (CRLF normalised to LF, per §8). This amendment writes
  **zero bytes** into `docs/status/requirement_status.yaml` — not into the frozen prefix, and
  not into the closure footer beyond it (§13.3 rejected that sub-option). The byte stream the
  digest is taken over is byte-for-byte identical, so the digest is unchanged and **A6 stays
  green with no index edit**. The digest covers volume 1 only; it does not and never did
  cover the index, so adding a key to the index cannot affect it.
- **A0, A1, A2, A3, A3b, A6, A7 — unchanged.** No behaviour, no bounds, no digests.
- **A8 gains one clause (c):** the current volume's header must contain the literal token
  `known_shape_anomalies:`. Clauses (a) the six `event` values and two `req` values, and (b)
  the two ceiling numbers, are unchanged. Rationale: the §13.8 header addendum is one of the
  two places a reader lands, and volume headers are propagated to future volumes by copy —
  clause (c) makes a copy that drops it fail, rather than quietly shrinking the declaration
  surface at the next roll.
- **§8's erratum, the freeze-and-roll shape, the header's existing text, the 23 instruction
  sites, §10, §11 — all untouched.** Out of scope for this amendment by instruction.
- **`test/support/status_history.ex` (§7) gains two things, signatures only:**
  - `parse_index/1`'s return map gains
    `known_shape_anomalies: [%{path:, entry_line:, req:, event:, kind:, field:, found_as:, found_line:}]`
  - `shape_anomalies(volume_path) :: [%{path:, entry_line:, req:, event:, kind:, field:, found_as:, found_line:}]`
    — the on-disk detector A4b compares against. Path-parameterised like every other function
    in the module; it must not know the index exists.
  - `anomalies/3` (the vocabulary detector A5 uses) is **unchanged** and must not start
    reporting shape violations.

### 13.8 Required addendum to the volume header (§4) — verbatim

Insert the following immediately after the `── ENTRY SHAPE — all five fields, in this order,
every time ──` block in `docs/status/requirement_status.v2.yaml`'s header, and carry it into
every future volume's header verbatim (the line numbers cite frozen volume 1, so they stay
valid forever):

```
#   ALL FIVE FIELDS ARE REQUIRED, INCLUDING `note:`. The timestamp field is named
#   `at:` — never `timestamp:`. Three volume-1 entries break this: line 4803
#   (REQ-053) and line 5050 (REQ-054) have no `note:` at all, and line 4896
#   (REQ-056) writes `timestamp:` where `at:` belongs. They are declared in
#   docs/status/requirement_status.index.yaml under `known_shape_anomalies:` and
#   are LEFT AS WRITTEN, for the same reason the `event: SCOPE-CHANGE` entries
#   are — correcting a past entry is what this file forbids. Do not copy them,
#   and do not "clean them up": assertion A4b in
#   test/docs/requirement_status_invariants_test.exs fails either way.
```

This is an **addition**, not a rewrite: no existing header line is changed, so A8 clauses (a)
and (b) are unaffected.

### 13.9 The three entries remain visible — where a reader lands

| Landing point | Declaration |
|---|---|
| `docs/status/requirement_status.index.yaml` — "THE ENTRY POINT", read by every appending agent at HOW-TO-APPEND step 1 | `known_shape_anomalies:`, all three, with cause (§13.4) |
| The current volume's header — read **in full** before every append | The §13.8 addendum, all three cited by line and req id |
| `mix test` | A4b names all three whenever it fails in either direction |
| This design artefact | §13.1's table, and the §5 cross-reference marker |

Volume 1's closure footer intentionally does **not** carry them (§13.3) — it is the only
landing point that would require writing to the frozen volume again.

### 13.10 Who applies this, and one instruction that is not optional

ELIXIR-DEV or DOC-UPDATER applies §13.4 (index) and §13.8 (volume-2 header); TEST-DESIGNER
applies §13.5–§13.7 to `test/support/status_history.ex` and
`test/docs/requirement_status_invariants_test.exs`. This artefact specifies; it applies
nothing itself, and it did not edit the index, the test files, or volume 1.

**Do not hand-tune the declared list to make A4b green.** Run A4b, read the full set it
reports, and compare it to the three records in §13.4. If it reports a **fourth** shape
violation, that is a new finding of the same kind, and the lawful response depends on
**which volume it is in** — say which, and what was done, in the handoff either way:

- **In a CLOSED, digest-pinned volume** — declare it in `known_shape_anomalies:` with its
  cause. The entry itself is never edited; that is what the exception list is for.
- **In the CURRENT volume** — **do NOT declare it. Fix it in the working tree before the
  commit lands.** The current volume is open and appendable, so the malformed entry is not
  yet history and correcting it is not a rewrite of a past entry. Declaring it is not merely
  discouraged here, it is impossible: A4b's closed-and-pinned rule (§13.5) fails any record
  whose `path:` names a volume that is not `status: closed` with a `frozen_prefix_sha256:`,
  so a record citing the current volume turns A4b red rather than green. That is deliberate —
  it is what stops `known_shape_anomalies:` from becoming a declare-to-silence mechanism.

> *(Corrected 2026-08-21 at Step 4 rework iteration 1, as MINOR-5, on the same narrow
> authorization as §8's erratum and no wider. As first written this paragraph said
> unconditionally to declare a fourth violation, which contradicts the closed-and-pinned rule
> §13.5 gained on re-amendment iteration 1 and would have been wrong guidance for the current
> volume — and §13.10 is the section an applying agent treats as authoritative. Nothing else
> in this artefact was changed by that pass.)*

Deleting a record, or narrowing the detector, to make the counts line up is the failure mode
this whole run exists to stop, in either volume.

### 13.11 Open questions raised by this amendment

1. **Should `note:` be optional rather than required?** Two of the three defects are a
   missing `note:`, which raises the fair question of whether the field is genuinely
   mandatory or was only ever conventional. This amendment does **not** re-decide it: the
   header has always documented five fields, 180 of 182 entries carry all five, and changing
   the rule is a vocabulary change, not a drift response. Recorded so a later run can decide
   it deliberately, in a header amendment, rather than by attrition.
   **Answered at Step 4e (2026-08-21), and recorded here rather than left open:**
   CODE-DESIGN-VALIDATOR checked the evidence directly and found `note:` **mandatory**, not
   conventional — volume 1's own header documented the five-field shape with `note:` as the
   fifth (lines 12–17) before these entries were written, volume 2's header states it in
   mandatory words, and 180 of 182 entries carry it. The one fair concession is a wording
   one: volume 1 phrased the shape as a template rather than using the word "required" —
   which is exactly what §13.4's `cause:` records. So the exception list is the correct
   instrument and a weakened A4b is not. No change to A4b follows from this.
2. **Should `known_anomalies:` be renamed `known_vocabulary_anomalies:`** now that a second
   anomaly class exists? Cosmetic, and it would touch A5's parse path and three existing
   records. Not proposed here; noted so the naming asymmetry is on record rather than a
   surprise.

---

## 13.12. POST-GATE AMENDMENT — 2026-08-21 — ISS-0193 — A5 gains the closed-and-pinned rule; a shared closure-warranted assertion (A10)

**Status:** amendment to the §13 amendment. Written 2026-08-21, closing ISS-0193 — an
incidental MAJOR finding CODE-DESIGN-VALIDATOR raised at ISS-0119's own Step 4e re-gate
(quoted in full in `docs/issues/ISS-0193.yaml`) but deliberately did not fix there, since
`known_anomalies:`/A5 had already cleared the hard gate on an earlier pass and widening that
pass would have been scope creep on it. §13.6 above carries the normative text for A5 itself
and for A10's dependency; this subsection is the record of the gap, the verification
performed, and the reasoning, per this project's own rule that a design records *why*, not
only *what*.

**Dispatched as:** `handoffs/WF03-ISS0193-20260821/step-02-code-designer.json`.

### 13.12.1 The gap, restated precisely

`known_shape_anomalies:`/A4b (§13.3–§13.5) and `known_anomalies:`/A5 (§13.6, §5) are both
"declare, don't edit" exception lists asserted by bidirectional set equality. A4b's own gate
(re-amendment iteration 1, §13's intro note) added a rule that a declared record may only cite
a **closed, digest-pinned** volume — closing the route where a fresh defect in the *current*
volume is silenced by declaring it in the same commit instead of fixing it. A5 never received
the equivalent rule, because the two mechanisms were introduced and gated in the same design
pass but A5's own text (§13.6, original) was written as "unchanged" — correctly, for what it
addressed (set equality, the three records, disjointness from shape anomalies), but silently
carrying forward the pre-existing absence of any volume restriction, which A4b did not have
either until its own re-gate. §13.6 above now carries the fix; this is the record of why it
was needed and how it was checked.

### 13.12.2 Verification against the actual index — exact lines checked

Task (a) requires this be verified against the file on disk, not assumed. Read in full during
this amendment (`docs/status/requirement_status.index.yaml`, current working tree):

- **The three `known_anomalies:` records** (lines 74–94 of the index): each has
  `path: docs/status/requirement_status.yaml` — lines 74, 81, 88. All three cite the same
  path; none cites `requirement_status.v2.yaml`.
- **Volume 1's own `volumes:` entry** (lines 32–52): `path: docs/status/requirement_status.yaml`
  (line 33) — the same path the three records cite — carries `status: closed` (line 34) and
  `frozen_prefix_sha256: "5a1a64ab0b999da3fd86be90109ecee46b9d538d9e9945c0d39fddb10075a804"`
  (line 46), a non-empty digest string.
- **Conclusion:** all three existing records satisfy A5's new closed-and-pinned rule.
  `path:` resolves to a volume entry, that entry's `status:` is exactly `"closed"`, and
  `frozen_prefix_sha256:` is present and non-blank. No record needs to move, and no existing
  behaviour changes for these three.
- **A10 compatibility, same read:** volume 1's `volumes:` entry also carries `lines: 5766`
  (line 38) and `bytes_working_tree: 361376` (line 39). Against `roll_rule.max_lines: 1200`
  and `roll_rule.max_bytes: 120000` (lines 21–22), `5766 > 1200` and `361376 > 120000` — both
  true, so volume 1 independently passes A10 (§13.12.4). Volume 2 (lines 54–64) carries
  `status: current`, so A10 does not apply to it (A10 only examines `status: closed` volumes),
  and no existing `known_anomalies:` or `known_shape_anomalies:` record cites it.

### 13.12.3 §13.3's parity bullet — reconciled in place, not here

Handled directly in §13.3 (the "reader who already understands one understands the other"
bullet, second bullet under "Why (i), on the merits"): that sentence was forward-looking when
written — A4b already had the closed-and-pinned rule and A5 did not, so the parity it claimed
was of intent, not of enforced behaviour. It is edited in place, at the sentence it concerns,
to say so explicitly and to state that ISS-0193 (this amendment) is what makes it now read as
settled fact. No separate rewording is needed here; duplicating the same prose in two places
would itself become a restatement hazard of the kind §7's A8 rationale (§7, A8 bullet) already
warns against.

### 13.12.4 A10 — the shared closure-warranted assertion

**The question, carried across from CODE-DESIGN-VALIDATOR's own MINOR-4 finding at ISS-0119's
Step 4e re-gate (quoted in `docs/issues/ISS-0193.yaml`, not re-derived here):** may a volume be
rolled to `closed` in the *same* commit that declares a record (shape or vocabulary) against
it? Answer, carried forward as-is: **the route is open today**, because nothing asserts a roll
was *warranted* — A3 (§7) only bounds the *current* volume from above, and `on_exceed` (the
index's `roll_rule:`) is prose, not a check. A volume closed early, with numbers still under
ceiling, would still pass A1/A2/A6/A7/A8/A4b's-and-A5's closed-and-pinned checks on a
correctly-performed roll. It is judged MINOR rather than MAJOR for the two reasons the finding
itself gives (fabricating a closure survives strictly less scrutiny than fixing the defect
would have taken; and the identical window is also the *legitimate* case — a defect noticed
only after a genuine roll must remain declarable) — both preserved unchanged from the
finding; this amendment does not re-litigate the severity, only builds the instrument the
finding proposed.

**The instrument — one assertion, shared by both mechanisms:**

- `StatusHistory.warranted_closure?(volume :: map(), max_lines :: pos_integer(), max_bytes :: pos_integer()) :: boolean()`
  — new public function in `test/support/status_history.ex`, alongside `within_bounds?/3`
  and following its convention (pure, explicit bounds, no hardcoded path). `volume` is one
  element of `parse_index/1`'s `:volumes` list (already carrying `status:`, `lines:`,
  `bytes_working_tree:` as parsed today for volume 1 — see §13.12.2). Returns `true` only
  when `Map.get(volume, :status) == "closed"` **and** (`Map.fetch!(volume, :lines) > max_lines`
  **or** `Map.fetch!(volume, :bytes_working_tree) > max_bytes`). Returns `false` for a
  non-closed volume, and **must raise (via `Map.fetch!/2`, not default-to-false via
  `Map.get/2`)** if a `status: closed` volume is missing either field — a closed volume
  silently missing its own recorded size is a data-integrity gap, not a "not warranted"
  verdict, and the two must not be conflated into the same boolean.
- **Why the index's recorded snapshot, not a live re-measurement of the file:** the volume is
  frozen; A6 (§7) already asserts the frozen prefix's bytes have not changed since closure via
  its digest. Re-measuring `lines`/`bytes_working_tree` live would (a) duplicate A6's job for
  the prefix portion and (b) pick up the closure footer's own bytes, which sit **beyond** the
  frozen prefix by design (§13.3's rejected sub-option, §8) and were never part of "the volume
  at the moment it was judged full". The index's `lines:`/`bytes_working_tree:` fields *are*
  that moment's measurement, recorded once at roll time and never touched again — using them
  is what "at the moment of closure" (ISS-0193's own phrasing) means operationally.
- **A10 itself — new top-level test, `test/docs/requirement_status_invariants_test.exs`,**
  placed after the existing A9 test: for every volume in `parse_index(@index_path).volumes`
  with `status == "closed"`, assert `SH.warranted_closure?(volume, roll_rule.max_lines,
  roll_rule.max_bytes)`. On failure, name every volume that failed, printing its `volume:`
  number, `path:`, recorded `lines:`/`bytes_working_tree:`, and the two ceilings, labelled
  "closed without exceeding either ceiling — closure was not warranted".
- **Sharing, not duplicating (the point of task (c)):** the test file's existing private
  helper `closed_and_pinned?/2` (used today only by A4b, `test/docs/requirement_status_invariants_test.exs`
  around the A4b findings block) is **renamed and extended** to
  `closed_pinned_and_warranted?(volumes :: [map()], roll_rule :: map(), record :: map()) ::
  boolean()`. It returns `true` only when the cited volume is found, `status == "closed"`,
  `frozen_prefix_sha256:` is present (the existing two checks, unchanged), **and**
  `SH.warranted_closure?(volume, roll_rule.max_lines, roll_rule.max_bytes)` (the new check,
  delegating to the one shared function above rather than re-comparing lines/bytes inline).
  Both A4b's `not_closed_and_pinned` finding (over `known_shape_anomalies:` records) and A5's
  new equivalent finding (over `known_anomalies:` records, §13.6) call this same renamed
  helper with their own record list — the roll-rule comparison itself is written exactly
  once, in `SH.warranted_closure?/3`.
- **Failure-message consequence:** both A4b's and A5's "closed-and-pinned" failure branch
  (§13.5, §13.6) must now be able to report *which* of the three reasons disqualified a record
  — not closed, not pinned, or not warranted — since `closed_pinned_and_warranted?/3`
  collapses to one boolean but the message must not. Specify the reason lookup as a sibling
  private function, e.g. `disqualifying_reason(volumes, roll_rule, record) :: :not_closed |
  :not_pinned | :not_warranted | :ok`, used only for message construction, never for the
  pass/fail verdict (the verdict stays a single boolean per record so the set-equality and
  closed-and-pinned findings compose the same way A4b already does today).

### 13.12.5 Exact `test/docs/requirement_status_invariants_test.exs` and `test/support/status_history.ex` changes

For **`test/support/status_history.ex`**:

- Add `warranted_closure?/3` as specified in §13.12.4 — a new public function, documented,
  alongside `within_bounds?/3`.
- No other function in this module changes. `parse_index/1`'s return shape is unchanged —
  `:volumes` already carries `status:`, `lines:`, `bytes_working_tree:` per §13.12.2's read of
  the current parser output; nothing new needs to be parsed.

For **`test/docs/requirement_status_invariants_test.exs`**:

- Add one new test, **A10** (§13.12.4), placed immediately after the existing A9 test.
- In the A5 test block: add the closed-and-pinned finding (mirroring the A4b findings block's
  shape) computed via the renamed `closed_pinned_and_warranted?/3` helper, and extend A5's
  failure message per §13.6's failure-output paragraph.
- Rename the existing private helper `closed_and_pinned?/2` to `closed_pinned_and_warranted?/3`
  (new `roll_rule` parameter) and update its one existing call site (A4b's findings function)
  to pass `roll_rule` through — `roll_rule` is already in scope there via `parse_index/1`'s
  return value, so no new parsing is needed at the call site either.
- Add the `disqualifying_reason/3` sibling helper (§13.12.4) and use it in both A4b's and A5's
  failure-message construction in place of the current binary "not closed-and-pinned" label.
- Two new negative-control fixtures, mirroring the existing A4b negative controls
  (`test/docs/requirement_status_invariants_test.exs`'s fixtures block): one closed, pinned,
  *unwarranted* volume (closed with `lines`/`bytes_working_tree` both under ceiling) cited by
  a declared record, to prove A10 (and the shared helper) actually bites rather than being
  green by construction — the same "negative control" discipline §13.5's own test coverage
  already applies to the closed-and-pinned rule.
- No change to A5's existing set-equality assertion, its bidirectionality, or the three
  existing `known_anomalies:` fixtures/records — task (a)/(e)'s constraint, preserved.

### 13.12.6 What does not change

- `docs/status/requirement_status.index.yaml` — **no edit required by this amendment.** The
  three existing `known_anomalies:` records already satisfy the new rule and A10 (§13.12.2).
  This amendment is a design-only change; ELIXIR-DEV/TEST-DESIGNER apply §13.12.4/§13.12.5,
  same division of labour as §13.10 established for §13's earlier amendment.
- A4b, `known_shape_anomalies:`, and the three shape-anomaly records (§13.3–§13.5) — unchanged
  in behaviour; A4b's closed-and-pinned check now additionally implies A10 via the shared
  helper, which volume 1 already satisfies (§13.12.2), so A4b's verdict is unaffected.
- Bidirectional set equality on A5, and the three existing `known_anomalies:` records —
  unchanged, per this amendment's own explicit instruction not to weaken or remove either.
