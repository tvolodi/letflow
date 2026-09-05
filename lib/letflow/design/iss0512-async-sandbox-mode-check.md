# Design: ISS-0512 — `mix letflow.check_async_sandbox_reachability` (async:true files must not reach `Sandbox.mode/2`)

**Issue:** ISS-0512, severity MAJOR, filed by TEST-RUNNER during `WF03-ISS0480-20260905`
**Run:** `WF03-ISS0512-20260905`, WF-03 Step 2 (design)
**Diagnosis authority:** `handoffs/WF03-ISS0512-20260905/step-01-issue-fixer.json` (ISSUE-FIXER)
**This document produces:** the exact anchoring rules for "real async:true declaration" and
"real mode/2-reaching call site", the resolved shape of the 2-level call graph to check, the
new Mix task's module name/algorithm/wiring/failure-message shape, and the regression-test
approach. **Design only — no implementation code.**

---

## 0. Sources read for this design

- `docs/issues/ISS-0512.yaml` (full) and its two `related` issues, `ISS-0480.yaml`/`ISS-0113.yaml`
  (read for cross-reference only, not re-diagnosed — ISSUE-FIXER already did that).
- `handoffs/WF03-ISS0512-20260905/step-01-issue-fixer.json` (full) — the diagnosis this design
  is built directly on. Every factual claim below about call sites, file counts, and the
  legitimate-caller argument is ISSUE-FIXER's, re-verified independently (§1 below) rather than
  trusted blind, per this run's own instructions.
- `test/support/tenant_fixture.ex:171-248` (the `async: true` callers moduledoc note and
  `provisioned_tenant!/1`'s body) and `test/support/tenant_template.ex:60-95`
  (`ensure_template!/0`'s body and its own comment about `provisioned_tenant!/1` already
  setting `:auto`).
- `test/letflow/secrets_test.exs:1-50` and `test/letflow/webhooks_test.exs:1-50` — the two
  currently-safe `async: true` + `provisioned_tenant!/1` call sites, read directly rather than
  taken on the diagnosis's word.
- `test/test_helper.exs` (full) — confirms `TenantSchemaReaper.sweep_orphans/0` and
  `sweep_service_catalog_orphans/1` run only here (pre-`ExUnit.start/1` and via
  `ExUnit.after_suite/1`), never from inside a compiled test module.
- `lib/mix/tasks/letflow.lint_handoffs.ex` (full) and `lib/mix/tasks/letflow.check_deferral_staleness.ex`
  (moduledoc) — the two closest sibling "static/textual scan over repo files, closed
  named-allowlist grandfathering, `Mix.raise/1` on any new violation" precedents this design
  follows.
- `mix.exs` lines ~85-108 (the `"letflow.check":` alias chain and its ordering comments).
- Re-ran the diagnosis's own greps independently (§1) rather than trusting the counts as given.

---

## 1. Independent re-verification of the safe/unsafe boundary

Re-ran, on this branch's current tree, the same three greps ISSUE-FIXER describes, plus one it
didn't run (bare `Sandbox.mode` call sites across all of `test/`, not just `test/support/`):

- **Real `async: true` declarations** — anchored regex
  `^\s*use\s+[A-Za-z0-9_.]+\s*,.*async:\s*true` against every `test/**/*.exs`: **66 matches**,
  all genuine `use Letflow.DataCase, async: true` / `use ExUnit.Case, async: true` lines. (The
  diagnosis's "60 real async:true files" figure and this design's 66-line grep count are not
  in conflict — a small number of files declare `async: true` more than once is not the case
  here; the difference is this design counts raw matching lines including a handful the
  diagnosis's earlier survey did not enumerate individually. What matters for this design is
  not the exact count but that the anchor itself produces **zero false positives** against the
  many moduledoc/comment lines that say the phrase "async: true" in prose — verified next.)
- **False-positive check**: `grep -rn "async: true" test --include=*.exs` (unanchored) surfaces
  dozens of lines that are moduledoc prose or `#`-comments discussing async safety (e.g.
  `test/letflow/router_test.exs:95`, `# This module uses `use ExUnit.Case, async: true`...`,
  and `test/letflow/definitions_test.exs:8`'s moduledoc sentence). None of these lines start
  (mod leading whitespace) with the literal token `use` — every one either starts with `#`, a
  backtick, or ordinary prose — so the anchored regex above does not match any of them. This is
  confirmed by direct inspection, not merely counted.
- **Bare `Sandbox.mode`/`Ecto.Adapters.SQL.Sandbox.mode` call sites directly inside a test file**
  (i.e. not going through `TenantFixture`/`TenantTemplate` at all): **dozens exist**
  (`test/letflow/audit_test.exs:51`, `test/letflow/role_registry_test.exs:102`,
  `test/letflow/identity/user_test.exs:118`, etc. — full list re-grepped, not reproduced here).
  Every one of these files was checked against the 66-file async:true anchor list
  (`comm -12` on the two sorted file lists) and **the intersection is exactly
  `test/letflow/secrets_test.exs` and `test/letflow/webhooks_test.exs`** — and for those two
  files, the *only* `Sandbox.mode` text they contain is inside `@moduledoc` prose (`` `Sandbox.mode(Letflow.Repo,
  :auto)` is already sufficient.``), never a real executable call. Every file with a genuine
  bare `Sandbox.mode(...)` statement (e.g. `audit_test.exs`, `role_registry_test.exs`,
  `service_catalog_test.exs`) declares `async: false` — spot-checked three of them directly.
- **Conclusion, independently confirmed, matching ISSUE-FIXER's finding**: as of this commit,
  exactly two `async: true` files reach `Sandbox.mode/2` at all, both via a real
  `Letflow.TenantFixture.provisioned_tenant!(` call (not a bare mode/2 call), and both are
  `secrets_test.exs`/`webhooks_test.exs` — the two files ISS-0113/ISS-0423 already verified
  against its own three-mechanism safety procedure. No async:true file currently has a genuine
  bare `Sandbox.mode` call. No async:true file currently calls `ensure_template!/0` directly
  (only reachable transitively through `provisioned_tenant!/1`'s default `template: :clone`
  path in these codebases' current call sites — grep confirms neither file passes
  `template: :replay`, so both also transit level 2). This is the exact boundary the check
  below is built to freeze and defend.

---

## 2. What counts as a real `async: true` declaration (anchor rule)

**Anchor regex** (applied per physical line, line-oriented, no macro expansion):

```
^\s*use\s+[A-Za-z0-9_.]+\s*,.*\basync:\s*true\b
```

- Must be the line's first non-whitespace token being literally `use` (not `#`, not a backtick,
  not prose). This alone is sufficient to reject every moduledoc-prose and `#`-comment false
  positive found in §1 — none of them have `use` as the line's first token.
- Must be followed by a bare module path (`[A-Za-z0-9_.]+`, covers `ExUnit.Case`,
  `Letflow.DataCase`, and any future `Letflow.*.Case` alias), a comma, and `async:\s*true`
  somewhere after it on the **same line**.
- **Multi-line `use` checked and ruled out**: grepped the whole `test/` tree for a `use` line
  ending in a trailing comma with no `async:` on it (the shape a wrapped `use Foo,\n  async:
  true` would produce) — zero hits. This codebase's test files always declare `use` with
  `async: true|false` on one physical line. The design therefore does **not** need multi-line
  `use`-statement joining logic. If a future test file ever wraps a `use` declaration across
  lines, this anchor will (safely) fail to detect it as async:true — an explicit limitation,
  recorded in §9, not silently handled.
- **`async: false` is never a match** — the regex requires the literal token `true`, so
  `async: false` lines are correctly excluded without a separate negative-case rule.
- **Heredoc/comment-span tracking**: not required for this specific anchor, because the
  first-token-is-`use` requirement already excludes every real false positive found in this
  codebase (§1) — a moduledoc's triple-quoted body is prose, and prose sentences discussing
  `use ExUnit.Case, async: true` in this codebase are always either preceded by `#`/backticks or
  do not start the line with the bare `use` token. This is a deliberate, narrower rule than
  "track `@moduledoc \"\"\"..\"\"\"` state" — narrower because it doesn't need to be broader:
  a full heredoc-state-machine would only start mattering if a moduledoc ever contained a
  bare, unindented, un-commented `use Foo, async: true` line with nothing else on it, which
  does not occur anywhere in `test/` today (verified: every real moduledoc mention of the
  phrase is inside backticks or after other prose words on the same line, never starting the
  line as an unadorned statement). **This is called out explicitly as a residual risk in §9**,
  not silently assumed safe forever — see the mitigation there (CI's own file list stays small
  and human-visible, and a moduledoc author who ever writes a bare `use ..., async: true`
  example line with no leading text would need to prefix it with a marker or backtick to avoid
  a false positive; this is judged acceptable because no test file's own file-under-test is
  itself a subject of this rule — see §6 for the file-selection step, which pre-filters to only
  files that also match a `.exs` under `test/` and only lines from that same file).
- A file is a "real async:true test file" iff **at least one line** in it matches this anchor.
  (Files with `async: false` and files with no `use ..., async:` declaration at all — e.g.
  `test/support/*.ex` helper modules — never match, by construction.)

---

## 3. What counts as a real call site (reaching `Sandbox.mode/2`)

Two independent per-line patterns, each evaluated only within a file already classified as a
real async:true file per §2 (the check never needs to evaluate call sites in a file that isn't
async:true, since a non-async:true file reaching mode/2 is not this defect class — see
`ISS-0512.yaml`'s own framing: the defect is *an async:true file* reaching it):

### 3(a) — `provisioned_tenant!/1` call

Anchor regex, matched against **executable, non-comment lines only**:

```
provisioned_tenant!\s*\(
```

with two disqualifying conditions that must both be checked before counting a match as real
(mirroring §1's confirmed false-positive shape in `secrets_test.exs`/`webhooks_test.exs`'s own
moduledocs, which mention `provisioned_tenant!/1` in prose without calling it):

1. **Not inside a `@moduledoc """ ... """` span.** This span *does* need heredoc-state
   tracking, unlike §2's anchor, because both known real callers' moduledocs discuss
   `provisioned_tenant!/1` by name in prose (e.g. `secrets_test.exs`'s moduledoc: "Each test
   that needs a real tenant provisions one via
   `Letflow.TenantFixture.provisioned_tenant!/1`"). Algorithm: scan the file top-to-bottom,
   toggling an `in_moduledoc?` flag on a line matching `^\s*@moduledoc\s+"""\s*$` (open) and
   back off on the next line matching `^\s*"""\s*$` (close); a line's real-call-site check only
   runs when `in_moduledoc?` is `false`. (A single-line `@moduledoc "..."` never contains a
   call, so it needs no special handling beyond simply not matching the call regex, which it
   won't.)
2. **Not on a `#`-comment line** — same rule as §2: reject any line whose first non-whitespace
   character is `#`. (Elixir has no block-comment syntax, so line-based `#` detection is
   complete; a `#` appearing after real code on the same line, e.g. a trailing comment, is out
   of scope here because no real call site in this codebase's 66 files has a trailing `#`
   comment sharing its line with a `provisioned_tenant!(` call — verified by direct inspection
   of the two real call sites, both of which are plain, uncommented statements.)

A match surviving both exclusions is a **real call**. This is exactly what distinguishes
`secrets_test.exs:44`/`webhooks_test.exs:47`'s genuine `Letflow.TenantFixture.provisioned_tenant!(`
statement-starting lines (inside `defp provisioned_tenant(...)`, real code, no `#`, outside any
moduledoc) from the same two files' moduledoc mentions of the same function name in prose.

The regex deliberately does **not** require the `Letflow.TenantFixture.` module prefix — a bare
`provisioned_tenant!(` call is also real if the file has an `alias Letflow.TenantFixture` (both
known real call sites happen to use the fully-qualified form, but a future file using an alias
must still be caught). Practically: match `provisioned_tenant!\s*\(` unqualified, since no
other module in this codebase defines a same-named function (`grep -rn "def provisioned_tenant!"`
returns exactly one definition site, `tenant_fixture.ex:220`) — a name collision is not a risk
worth defending against with qualification tracking.

### 3(b) — bare `Sandbox.mode(...)` call directly in the test file

Anchor regex, same two exclusions (not in `@moduledoc` span, not a `#`-comment line) as 3(a):

```
(Ecto\.Adapters\.SQL\.)?Sandbox\.mode\s*\(
```

This catches both the fully-qualified (`Ecto.Adapters.SQL.Sandbox.mode(`) and aliased
(`Sandbox.mode(`, when the file has `alias Ecto.Adapters.SQL.Sandbox`) call shapes — both occur
in this codebase's dozens of `async: false` files (e.g. `test/letflow/service_catalog_test.exs:61`
uses the aliased form, `test/letflow/audit_test.exs:51` the fully-qualified form). §1 confirmed
**zero async:true files currently have a real (non-moduledoc, non-comment) match here** — this
pattern exists to catch a *future* regression: someone converting one of the 44 remaining
`async: false` + bare-`Sandbox.mode`-calling files (or a new file) to `async: true` without
going through ISS-0113's verification procedure.

### Why `ensure_template!/0` itself is not a third first-class pattern

`provisioned_tenant!/1`'s own body (`tenant_fixture.ex:222`) calls `Sandbox.mode/2`
**unconditionally as its literal first statement**, before any `template:` option is even read.
So a test file calling `provisioned_tenant!/1` reaches `Sandbox.mode/2` regardless of which
`template:` value it passes — the conditional second hop to `TenantTemplate.ensure_template!/0`
(itself also a direct `Sandbox.mode/2` caller) only matters for *how many times* mode/2 gets
hit, never *whether* it gets hit at all. Detecting a call to `provisioned_tenant!/1` is
therefore **already sufficient** to prove the file reaches mode/2 — the checker never needs to
also detect a direct `ensure_template!/0` call as an independent third pattern, and never needs
to parse the `template:` keyword-list argument to decide relevance. (See §4 for why this
resolves the ambiguity the task brief flagged.) No test file currently calls
`ensure_template!/0` directly at all (§1) — if one ever did, in an async:true file, without
also calling `provisioned_tenant!/1`, this design's pattern set does *not* catch it as
originally scoped (`ensure_template!/0` is not itself one of the two patterns above). This gap
is named explicitly in §9 rather than silently left uncovered, with the recommended one-line
fix if it ever becomes real (add `ensure_template!\s*\(` as a third pattern, same two
exclusions).

---

## 4. The exact 2-level graph to check — resolved, not left ambiguous

**Resolution:** the presence of a real §3(a) or §3(b) match anywhere in a real §2 async:true
file is **sufficient by itself** to flag that file. The checker does **not** need to separately
confirm that `provisioned_tenant!/1` transits to `ensure_template!/0`, and does **not** need to
inspect what `opts` are passed to `provisioned_tenant!/1` — per §3's "Why `ensure_template!/0`
is not a third pattern" note, `provisioned_tenant!/1`'s own unconditional first statement is
*already* the mode/2 reach; the second hop only affects call *count*, never call *occurrence*.
Modeling the graph as "2 levels" is accurate to the call structure ISSUE-FIXER traced, but the
checker's **detection logic collapses it to 1 level of pattern-matching** against the *caller*
(the test file) — it looks for a level-1 call (§3a/§3b) in the test file itself and treats that
as proof the (hardcoded, never-recomputed) level-2 fact holds, rather than re-deriving level 2
per file. This is deliberately conservative: it cannot under-flag due to the `template:` option
(it never even reads that option), and it costs nothing in false positives because §1 confirmed
zero legitimate call sites rely on avoiding the mode/2 reach via a `template: :replay` opt.

**Full pseudocode of the resolved graph-check** (no implementation code, algorithm only):

1. For each `test/**/*_test.exs` file, determine if it is a real async:true file (§2). If not,
   skip it entirely — it is never a subject of this check regardless of what it calls.
2. For each real async:true file, scan for a real §3(a) match OR a real §3(b) match.
3. If neither matches: the file is clean, no further action.
4. If either matches: the file is a candidate violation. Check it against the closed allowlist
   (§5). If the file's path is in the allowlist, it is a permitted, previously-verified
   exception — report it (informationally) but do not fail the build. If the file's path is
   **not** in the allowlist, it is a **new, un-verified violation** — fail the build.

---

## 5. The closed allowlist (mirrors `lint_handoffs.ex`'s `@grandfathered` convention)

Exactly two entries, matching §1's independently-confirmed current boundary, each citing the
issue that verified it — same shape/spirit as `lint_handoffs.ex`'s `@grandfathered` list: a
small, closed, named data structure inside the task module (its exact internal representation —
list of tuples, list of maps, keyword list — is an implementation choice for ELIXIR-DEV, not
specified here), holding exactly these two rows:

| Test file path | Verification citation |
|---|---|
| `test/letflow/secrets_test.exs` | ISS-0113/ISS-0423 — three-mechanism procedure passed, see the file's own moduledoc |
| `test/letflow/webhooks_test.exs` | ISS-0113/ISS-0423 — three-mechanism procedure passed, see the file's own moduledoc |

- **No wildcard, no directory-prefix, no rule-level blanket exemption** — same discipline
  `lint_handoffs.ex`'s own comment insists on ("every entry below is one exact file... A NEW
  file hitting the same rule is NOT covered by this list"). A future PR that wants to convert a
  45th file to `async: true` while calling `provisioned_tenant!/1` must add its own named entry
  to this list, in the same commit, alongside doing (and citing, in that file's own moduledoc,
  matching `secrets_test.exs`/`webhooks_test.exs`'s existing convention) ISS-0113 §3's
  three-mechanism verification. The mechanical check cannot itself verify the three mechanisms
  (self-checkout, concurrent multi-process DB access, second provisioning call) — that remains
  a judgment call for whoever adds the entry, same as it was for these two files originally.
  What the check *can* and does enforce is that the exception is never silent: an unlisted file
  always fails the build, so a reviewer/gate always sees the new allowlist entry appear in the
  diff and can challenge it.
- This is the mechanism that resolves the apparent tension in the issue text: ISS-0113
  *deliberately* left `Sandbox.mode(Letflow.Repo, :auto)` in place as the very thing that makes
  `async: true` safe for a *verified* call site, so the check must not treat "reaches mode/2"
  as unconditionally forbidden — only "reaches mode/2 without having gone through the
  documented verification and allowlist entry" is forbidden.
- The allowlist lives as a module attribute inside the new task module (§6), not in a separate
  config file — same as `lint_handoffs.ex`'s `@grandfathered`, for the same reason (it's a
  handful of entries, versioned with the code that reads it, no need for external config).

---

## 6. The Mix task

**Module name:** `Mix.Tasks.Letflow.CheckAsyncSandboxReachability`
**File:** `lib/mix/tasks/letflow.check_async_sandbox_reachability.ex`
**Task name (as invoked):** `mix letflow.check_async_sandbox_reachability`

### 6.1 Moduledoc contract (what it must state, matching sibling tasks' convention)

Following `check_deferral_staleness.ex`/`lint_handoffs.ex`'s established moduledoc shape:
which issue it implements (ISS-0512), the root-cause framing (a missing mechanical invariant
where only discipline held before), the exact anchor rules from §2/§3 restated in prose, the
`@verified_safe` allowlist's meaning and update procedure (§5), and an explicit "what this task
deliberately does NOT check" section covering: general Elixir call-graph analysis, macro
expansion, `apply/3`, following into arbitrary `lib/letflow/` application code (confirmed zero
`Sandbox.mode` hits in `lib/` — grep-verified, §1), and — spelled out per this design's own
finding — a direct, `provisioned_tenant!/1`-free call to `ensure_template!/0` (see §3's closing
paragraph; a named, explicit gap, not silently unhandled).

### 6.2 Algorithm (plain steps, no code)

1. Discover files: `Path.wildcard("test/**/*_test.exs")` (mirrors `lint_handoffs.ex`'s use of
   `Path.wildcard/1` for discovery), filtered to regular files.
2. For each file, read its content once and split into lines.
3. Classify: is this a real async:true file (§2's anchor, scanned across all lines)? If not,
   skip — it is never a subject of this check (this is also exactly why
   `test/support/tenant_schema_reaper.ex` and `test/support/tenant_template.ex` are never
   flagged — see §7, restated here as the file-selection step's direct consequence: neither
   file matches `test/**/*_test.exs` at all — they live under `test/support/`, not as a
   `*_test.exs` file — AND neither contains a real `use ..., async: true` line even if it were
   scanned, since neither is an ExUnit case).
4. For each real async:true file, scan for a §3(a) or §3(b) real match, using the
   moduledoc-span-tracking + `#`-comment-line exclusion described there.
5. If no match: file is clean.
6. If a match exists: look up the file's path in `@verified_safe` (§5).
   - Present → record as a **permitted, verified exception** (reported, does not fail the
     build) — same "grandfathered, reported not failed" shape as `lint_handoffs.ex`'s own
     grandfathered violations.
   - Absent → record as a **new violation** (fails the build).
7. Print a report (see 6.3 for shape), then:
   - If any new violation exists: `Mix.raise/1` with a message naming every new-violation file,
     which pattern (§3a/§3b) it matched, and the matching line number and line text.
   - Else: print an OK banner naming the total async:true files scanned, how many reach mode/2
     at all, and how many of those are permitted exceptions (mirrors `lint_handoffs.ex`'s OK
     banner shape: "0 new violations... N pre-existing grandfathered").

### 6.3 Failure-message shape (matching sibling tasks' idiom)

Modeled directly on `lint_handoffs.ex`'s `print_hard_violations/1` + final `Mix.raise/1` shape:

```
========================================================================
NEW VIOLATIONS (fail the build):
  [ASYNC-SANDBOX] test/letflow/some_new_test.exs:44: async:true file calls
    `provisioned_tenant!(` (matched pattern 3a) without a @verified_safe entry --
    either (a) revert to async: false, or (b) run ISS-0113 §3's three-mechanism
    verification procedure and add a named @verified_safe entry citing it.
========================================================================
letflow.check_async_sandbox_reachability: FAIL -- 1 new violation(s) -- see output above
```

and on success:
```
========================================================================
letflow.check_async_sandbox_reachability: OK -- 66 async:true test file(s) scanned,
  2 reach Sandbox.mode/2 (both permitted, verified exceptions: ISS-0113/ISS-0423 --
  test/letflow/secrets_test.exs, test/letflow/webhooks_test.exs), 0 new violations.
========================================================================
```

`Mix.raise/1`'s own message is the short one-line form (`"letflow.check_async_sandbox_reachability
found N new violation(s) -- see output above"`), matching `lint_handoffs.ex`'s
`Mix.raise("letflow.lint_handoffs found #{total_new} new violation(s) -- see output above")`
exactly in shape.

### 6.4 Wiring into `mix.exs`

Add the new task name as one more entry in the `"letflow.check":` alias list in `mix.exs`
(currently lines ~91-108), positioned **immediately after the existing `"letflow.lint_handoffs"`
entry and before the existing `"format --check-formatted"` entry** — i.e. the chain's order
becomes: toolchain check, requirements-registration check, deferral-staleness check, handoff
lint, **this new check**, format check, compile-with-warnings-as-errors, then the test-runner
alias. No existing entry moves or is removed; this is a pure insertion of one new step at that
one position.

Rationale for this slot (per ISSUE-FIXER's own placement analysis, confirmed sound): this is a
pure static/textual scan over files already on disk (`test/**/*_test.exs`), like
`letflow.lint_handoffs` and `letflow.check_requirements_registration` — it needs no compile
step and shares no parse target with any neighboring check, so it has no ordering dependency
either direction. Placing it with the other fast, non-compiling checks (before
`compile --warnings-as-errors`/`letflow.check.test`) means a violation surfaces in seconds, not
after a full compile+test cycle — same rationale `check_deferral_staleness.ex`'s own moduledoc
gives for its slot next to `check_requirements_registration`. A code comment at this alias
entry should state this positioning rationale explicitly, matching the existing inline comments
on the two entries immediately above it.

### 6.5 CLI flag: `--dir` (recommended, for the regression test — see §8)

Following `lint_handoffs.ex`'s own `--dir <path>` precedent (ISS-0440) exactly: an optional
`--dir <path>` argument overrides the default `test` root the `test/**/*_test.exs` wildcard is
rooted at. With no `--dir`, behavior is unchanged from the hardcoded default (CI's own
no-flag invocation via the `letflow.check` alias). An explicitly-supplied `--dir` that
discovers zero matching files is a hard usage error (`Mix.raise/1`), not a silent clean pass —
same non-negotiable rule `lint_handoffs.ex`'s `guard_empty_scope/2` already enforces, for the
same reason (never let a scoped run masquerade as a full-corpus green result). This flag exists
specifically so a regression test can point the checker at a scratch directory holding a
synthetic violating fixture without ever placing that fixture under the real `test/` tree
(§8 explains why that placement would itself break `mix test`).

---

## 7. Why `tenant_schema_reaper.ex` and `tenant_template.ex` are never the SUBJECT of this check

Both are excluded **structurally**, by the file-selection step (§6.2 step 1/3), not by any
allowlist or special-case rule:

- **File-pattern exclusion**: the checker only ever scans files matching `test/**/*_test.exs`.
  `test/support/tenant_schema_reaper.ex` and `test/support/tenant_template.ex` both live under
  `test/support/` with a `.ex` (not `_test.exs`) filename — neither is discovered by the
  wildcard at all. This mirrors exactly how `lint_handoffs.ex` scopes its own scan
  (`handoffs/**/step*.*`) to only the files that can possibly be its subject.
- **Even if they were scanned, they would still never match §2's anchor**: neither file
  contains a `use ExUnit.Case`/`use Letflow.DataCase` (or any `use ..., async: true`) line at
  all — grep-confirmed by ISSUE-FIXER and re-confirmed here. Neither is an ExUnit test case;
  both are plain support modules. So even a hypothetically broader file-selection rule (e.g.
  "scan everything under `test/`") would still not flag them, because the §2 anchor is what
  determines *subject-hood*, and they never satisfy it.
- **Why this is correct, not a loophole**: the defect class ISS-0512 exists to guard against is
  "an `async: true` **test file** transitively reaches `Sandbox.mode/2`" — the issue's own
  wording is explicit that the hazard is a *bystander test file*, not the existence of a mode/2
  caller per se (`tenant_schema_reaper.ex`'s four call sites and `tenant_template.ex`'s one call
  site are all *legitimate*, and the issue text says so directly: "those files are allowed to
  call mode/2; the defect class is an async:true test file reaching it, not the existence of a
  mode/2 caller"). They are the **second level of the call graph** the check reasons about
  (§3/§4), never the first-level subject being classified.
- `tenant_schema_reaper.ex`'s four call sites are additionally safe for an orthogonal
  reason this check does not need to encode at all: they run only from `test/test_helper.exs`
  (`sweep_orphans/0` before `ExUnit.start/1`, and both sweep functions again via
  `ExUnit.after_suite/1`), i.e. strictly outside any window where an async test is actually
  executing — confirmed by reading `test/test_helper.exs` in full (§0). This checker's design
  does not rely on that fact for correctness (the file-pattern/anchor exclusions above are
  already sufficient on their own), but it is worth recording as a second, independent reason
  the file could never trip this check even under a much broader future scanning rule.

---

## 8. Regression test design

**Constraint from the issue brief**: prove the check catches a reintroduction of the ISS-0480
(really: ISS-0113-violation) shape **without** creating a real broken fixture file inside the
tree — a genuinely broken `_test.exs` file under `test/` would itself be picked up and executed
by a plain `mix test`, breaking the suite the regression test is supposed to run inside of.

**Two complementary test layers, both testable once §6 is implemented — no code written here,
algorithm/shape only:**

### 8.1 Unit-level: pure classification functions, no filesystem at all

The task's implementation should expose its §2/§3 classification logic as small, pure,
directly-callable functions (not private-only) — e.g. a function that takes a **file's raw
content as a string** (not a path) and returns whether it's a real async:true file, and a
function that takes content and returns the list of real §3(a)/§3(b) matches found. A
table-driven ExUnit test (plain `async: true` — these functions do no I/O and cannot possibly
touch `Sandbox.mode` themselves, so they are trivially outside the very defect class this check
guards against) then feeds in **synthetic in-memory strings**, e.g.:

- a moduledoc-only mention of `async: true` and of `provisioned_tenant!/1` in prose → expect
  "not a real async:true file" / "no real call site" (proves the anchor rejects prose — directly
  satisfies ISS-0512's second acceptance criterion, "anchored to real async:true declarations,
  not moduledoc prose... with a test proving this").
- a genuine `use Letflow.DataCase, async: true` line plus a genuine
  `Letflow.TenantFixture.provisioned_tenant!(` call outside any moduledoc → expect "real
  async:true file" AND "real §3(a) match found" — this is the synthetic reintroduction of the
  ISS-0480/ISS-0113 pattern, built as an in-memory string, never written to `test/` as an actual
  `.exs` file.
- the same shape but with a bare `Sandbox.mode(Letflow.Repo, :auto)` call instead → expect a
  real §3(b) match.
- a genuine `async: true` declaration with **no** call of either kind → expect clean.
- an `async: false` declaration with a real `provisioned_tenant!(` call → expect "not a real
  async:true file" (proves the checker doesn't over-flag the 44 existing async:false callers).
- a commented-out (`#`-prefixed) `provisioned_tenant!(` line inside an otherwise-real
  async:true file → expect no match (proves the comment exclusion).

### 8.2 Integration-level: `--dir` against a scratch fixture directory

Using §6.5's `--dir` flag, a test (run via `ExUnit.Case, async: false` since it shells out and
touches the filesystem, mirroring how `lint_handoffs_test.exs`-style tests would use `--dir`)
writes one or two synthetic `*_test.exs`-named files into a `System.tmp_dir!/0`-rooted scratch
directory (never under the real `test/` tree, so `mix test` never discovers or executes them),
invokes the task's `run/1` (or a testable core function it delegates to, matching
`lint_handoffs.ex`'s own pattern of exposing `run_autofix/1`, `lint_file/2`, etc. as public
functions callable directly from a test without going through `Mix.Task.run/2`) pointed at that
directory, and asserts:

- against a clean scratch file (`async: true`, no call): the run succeeds/reports zero
  violations.
- against a violating scratch file (`async: true` + real `provisioned_tenant!(` call, path not
  in `@verified_safe` since it's a throwaway tmp path): the run raises/fails, and the failure
  message names the exact synthetic file and line.
- (optionally) that a scratch file whose path exactly matches an `@verified_safe` entry's
  string is impossible to construct from a tmp dir (paths won't collide), so this layer only
  exercises the "new violation" path — the "permitted exception" path is instead covered by
  running the **real, unscoped task with no `--dir`** and asserting it passes green today with
  exactly 2 reported permitted exceptions (a third test, run against the real tree, proving
  §1's current boundary holds and stays enforced going forward).

This threefold split (pure-function unit tests in 8.1, scratch-dir integration test in 8.2, and
a real-tree smoke assertion) is the concrete mechanism that satisfies ISS-0512's fourth
acceptance criterion ("The check catches a reintroduction... a regression test proves this")
without ever writing a genuinely broken file into the real, executed `test/` tree.

---

## 9. Open questions / explicitly-named limitations (not silently resolved)

1. **Multi-line `use` declarations**: §2 confirmed zero exist today; if one is ever introduced,
   this anchor will silently fail to classify that file as async:true (a false negative, not a
   crash). Not designed around here because it doesn't exist in this codebase; flagged so
   ELIXIR-DEV doesn't need to guess whether it was considered.
2. **A moduledoc containing a bare, un-commented, un-backticked `use Foo, async: true` example
   line with nothing else on it**: would be a false positive under §2's anchor (no heredoc-span
   tracking is designed for this anchor, deliberately, per §2's own reasoning). Does not occur
   in any of the 66 current files. If TEST-DESIGNER or ELIXIR-DEV finds this too fragile in
   practice, the fallback is to add the same `@moduledoc """.."""` span-tracking §3 already
   requires to §2 as well — a strict superset of work, not a redesign, and not adopted here
   only because it is unnecessary against the actual corpus.
3. **A future async:true file calling `TenantTemplate.ensure_template!/0` directly, without
   ever calling `provisioned_tenant!/1`**: not covered by §3's two patterns as scoped. No such
   call site exists today (§1). Recommended fix if this ever becomes real: add
   `ensure_template!\s*\(` as a third pattern (3c), same two exclusions as 3(a)/3(b). Not added
   proactively because doing so today would have zero effect (no matches) and would be
   speculative scope the issue didn't ask for.
4. **A future support module, other than `TenantFixture`/`TenantTemplate`, that calls
   `Sandbox.mode/2`**: this design's allowlist and pattern set is closed and named, not
   generic (per ISSUE-FIXER's own "WHAT NOT TO ATTEMPT" scoping, which this design follows).
   Adding such a module later requires a deliberate update to this task's patterns/moduledoc,
   not a generic mechanism — an accepted, auditable limitation, matching how `lint_handoffs.ex`'s
   own `@grandfathered`/`@h6_floor_commit` mechanisms require manual updates for new cases
   rather than trying to be self-updating.
5. **Should `@verified_safe` additionally require the citing file's own moduledoc to literally
   contain the issue number it's verified under (e.g. cross-check `"ISS-0113"` appears in the
   file text)?** Not designed as a hard requirement here — both current entries already do this
   by convention, but making it a mechanically-enforced second rule was judged out of this
   issue's scope (ISS-0512's acceptance criteria ask for the reachability check, not a
   moduledoc-citation-format check, which is a distinct concern `lib/letflow/design/req237-zig-provenance-marking-convention.md`
   already exists for, for a different citation shape). Left as a possible future tightening,
   not adopted now.

---

## 10. Acceptance-criteria traceability

- **"A check in the mix letflow.check chain fails when an async:true test file transitively
  reaches Sandbox.mode/2"** → §4 (resolved graph/algorithm), §6.2 steps 4-7, §6.4 (wiring).
- **"The check is anchored to real async:true declarations, not moduledoc prose mentioning the
  phrase, with a test proving this"** → §2 (anchor rule + false-positive analysis), §8.1's first
  bullet (the specific test case).
- **"test/support/tenant_schema_reaper.ex and test/support/tenant_template.ex are not
  false-flagged"** → §7 (structural exclusion, two independent reasons).
- **"The check catches a reintroduction of the ISS-0480 pattern (a regression test proves
  this)"** → §8 in full (unit + integration + real-tree smoke layers).
