# ISS-0119 — Fix design: restore an executable append-only safeguard for the requirement status history

**Run:** WF03-ISS0119-20260821 · **Step:** 2 (CODE-DESIGNER) · **Issue:** ISS-0119 (GH#373, queue task 186)
**Built on:** `handoffs/WF03-ISS0119-20260821/step-01-issue-fixer-diagnose.json` `result.summary`
**Implemented by:** ELIXIR-DEV at Step 3 (docs/process change; no `lib/` runtime code except the Step 4 test)

This is a design artefact. It contains no implementation. The one place finished prose
appears verbatim is the required new header/footer/index text — the handoff sanctions
that explicitly, because the defect *is* the current header's wording.

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
#
# 5. Verify you appended and did not replace. The line count must GROW:
#      git diff --numstat docs/status/requirement_status.v2.yaml
#    Any nonzero deletion count on this file is a defect. Revert and redo.
#
# 6. Apply the roll rule below.
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
- **A4 — Vocabulary conformance.** Across every volume, every `req:` value matches
  `REQ-\d{3}` or `SCOPE-CHANGE`; every `event:` value is one of the six legal values; every
  entry carries all five fields in order with a parseable ISO-8601 `at:`. Exceptions only
  as declared in A5.
- **A5 — Anomaly set is exact (protects C2 in both directions).** The set of
  vocabulary violations found on disk, keyed by `{path, line, field, value}`, equals the
  index's `known_anomalies:` set exactly. A new violation fails (drift detected); a missing
  one fails (a past entry was silently normalized or deleted — the very act the append-only
  rule forbids).
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
