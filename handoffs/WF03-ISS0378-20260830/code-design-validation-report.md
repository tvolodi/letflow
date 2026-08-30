# CODE-DESIGN-VALIDATOR Report — ISS-0378

**Run:** WF03-ISS0378-20260830
**Verdict:** PASS
**Design reviewed:** `lib/letflow/design/iss0378-poller-ac7-test-fix.md` (full)
**Also read in full:** `handoffs/WF03-ISS0378-20260830/step-02b-code-design-validator.json`,
`handoffs/WF03-ISS0378-20260830/issue-fixer-diagnosis.md`

## Checks performed and results

1. **Line ranges verified against the live file.** Read
   `test/letflow/scheduler/poller_test.exs` lines 300-368 directly. Confirmed exactly as
   the design states: `resolve_base_ref!/0` at lines 329-337 (`defp resolve_base_ref! do`
   at 329, closing `end` at 337), the `describe` block opens at line 339 with the title
   text `"AC7: retention runs on Poller's own process -- no second ticker, application.ex
   untouched"`, the zero-diff test spans lines 340-353, and the surviving sibling test
   (`"lib/letflow/scheduler/ contains exactly one GenServer module (Poller) -- no second
   ticker"`) runs lines 355-366, closing the describe block at 367 and the module at 368.
   File is 368 lines total, matching the design doc's stated pre-edit length. No drift.

2. **`resolve_base_ref!/0` single-call-site claim re-verified independently.**
   `grep -rn resolve_base_ref test/ lib/` returns exactly two hits, both inside
   `poller_test.exs`: the `defp` at line 329 and its sole call at line 341 (inside the
   test being deleted). No other file under `test/` or `lib/` references it. Deletion
   introduces no dangling reference.

3. **Test isolation confirmed.** The deleted test only shells out to `git diff --stat`
   and asserts on the string result — no DB writes, no shared state, no process
   dictionary/application-env mutation. The file uses `use Letflow.DataCase, async:
   false` (sandbox-per-test transactions), not an ordering-dependent shared-state
   pattern. No test in the file (including the surviving sibling) references anything
   produced by the deleted test or by `resolve_base_ref!/0`. ExUnit does not guarantee
   intra-describe test order here (no `seed: 0` or manual ordering markers in this
   file), and none is relied upon.

4. **Coverage cross-check against REQ-186 / test/specs/REQ-186.md performed
   independently.** Read `docs/requirements.yaml`'s REQ-186 entry (10 acceptance
   criteria, lines ~99-109) and `test/specs/REQ-186.md` in full. Confirmed: the real AC7
   is "timer reaching max fire retries → `failed` + one `dlq_entries` row", mapped to
   `test/letflow/scheduler_test.exs:"AC7: ..."` — unrelated to `application.ex` and
   already covered, untouched by this fix. AC9 ("no route/controller file added") is
   explicitly required to be checked structurally (not via git history) and is already
   satisfied by `test/letflow/scheduler_test.exs:"AC9: ..."`. Neither AC1-AC10 nor the
   test spec's coverage checklist references an "application.ex zero diff" property
   anywhere. Deleting this test removes zero real AC coverage — it was tracking an
   undocumented, unmapped property, and its only defensible substance ("no second
   ticker added") remains covered by the untouched sibling GenServer-count test.

5. **No implementation code fences.** `grep -n '```' lib/letflow/design/iss0378-poller-ac7-test-fix.md`
   returns zero matches. The design doc quotes fragments of real code inline
   (e.g. `defp resolve_base_ref! do`) as prose identifiers for review purposes, not as
   fenced, reproduced `.exs` bodies — consistent with the two prior rework rounds on
   this same run (commits `3680243`, `290c6b2`) that already stripped literal code from
   this doc.

6. **Anti-patterns.md recommendation is proportionate.** Verified the target entry
   ("A test scoped to one specific historical commit SHA breaks the moment that commit
   is squash-merged away") exists at `docs/anti-patterns.md:1751`. Verified the
   `**Recurrence.**` paragraph convention the design doc asks the implementer to follow
   is a real, existing pattern in this file (`docs/anti-patterns.md:1677`, under the
   `mix format` entry) — not an invented format. The design asks for one short paragraph
   appended to an existing entry, not a new heading or elaborate rewrite: proportionate.

## Conclusion

All six validation checks pass. The design is unambiguous, mechanically specified,
contains no implementation code, correctly identifies zero AC-coverage loss, and its
anti-patterns.md recommendation is right-sized. Routed to ELIXIR-DEV for Step 3
(IMPLEMENT) per WF-03 — a test-file-only edit, same procedure as WF-02 Step 2a/2b.
