# Design: ISS-0068 format-drift fix

## Scope

Mechanical fix only. No new modules, functions, schemas, or behavior change.
This doc exists to satisfy WF-03 Step 2 (design precedes implementation) for
an issue whose entire fix is "run the formatter" — there is no design
surface beyond the procedure below.

## 1. The fix

**Action:** run `mix format` against exactly the 14 files listed in
ISS-0068 (not the whole tree).

**Why scoped, not whole-tree:** ISS-0068's diagnosis already enumerates the
exact 14 files that fail `mix format --check-formatted` under this host's
Elixir 1.18.3/Mix 1.18.3 toolchain; every other file in the tree already
passes the check (per the same diagnosis run). Formatting the whole tree
would touch zero additional files in practice but widens the blast radius
of the change for no benefit and makes the diff harder to eyeball as
"pure reflow, nothing else." Scoped list is safer to review.

Files (unchanged from ISS-0068):

```
lib/letflow/definitions/graph.ex
lib/letflow/engine/plugin_interface.ex
lib/letflow/identity_migration.ex
test/letflow/definitions/graph_test.exs
test/letflow/engine_cancel_instance_test.exs
test/letflow/engine/expr_test.exs
test/letflow/engine/parallel_gateway_test.exs
test/letflow/engine/service_task_test.exs
test/letflow/engine/snapshot_writer_test.exs
test/letflow/engine/task_activation_test.exs
test/letflow/engine/variable_merge_test.exs
test/letflow/event_store_test.exs
test/letflow/sandbox_pool_test.exs
test/support/tenant_schema_reaper_test.exs
```

**Command:** `mix format <file1> <file2> ... <file14>` (or equivalently
`mix format` with each path listed) run under this host's toolchain
(Elixir 1.18.3 / Mix 1.18.3, OTP 27) with no `LETFLOW_*` toolchain
override in effect.

**Expected diff shape:** whitespace/line-break/paren-placement reflow only
— e.g. a long `assert ... =` wrapping onto multiple lines, argument lists
re-indented. No identifier, literal, operator, or logic token should
change. If `mix format` produces any change beyond this shape on any of
the 14 files, stop and escalate to ISSUE-FIXER rather than committing —
that would mean the file's content actually drifted, not just its
formatting, and this design does not cover that case.

## 2. Verification ELIXIR-DEV must run after formatting

Run in order, all must pass before proceeding to REVIEWER:

1. `git diff --stat` — sanity-check the 14 files show a plausible
   reflow-sized diff (roughly balanced `+`/`-` line counts per file; no
   file shows a large one-sided insertion/deletion that would suggest
   content loss).
2. `git diff` (full) — spot-check that every hunk is whitespace/paren
   reflow, no token-level change. This is the actual verification; step 1
   is just a fast pre-check.
3. `mix format --check-formatted` — must exit 0 (was the failing gate;
   confirms the fix closes it).
4. `mix compile --warnings-as-errors` — must stay clean (already clean
   per ISSUE-FIXER's diagnosis; re-run to confirm formatting didn't
   introduce a warning).
5. `mix test` (with `LETFLOW_DEV_DB_CONFIRMED=1` per repo convention) —
   must stay clean at the same pass count ISSUE-FIXER already recorded (5
   properties, 1029 tests, 0 failures). A changed test count would mean
   the diff touched more than formatting.

If all five pass, the fix is complete and ready for REVIEWER — no
SECURITY-REVIEWER gate applies (no tenant-data path touched: this is a
formatting-only change to already-reviewed files).

## 3. Out of scope: toolchain pinning (follow-on only)

ISS-0068 is the second occurrence of this root-cause class (first:
ISS-0008/GH#12). The recurring cause is that this repo runs 4 concurrent
hosts (per CLAUDE.md/hetzner-orch's session brief), each free to run
whatever local Elixir/Mix toolchain it has (README only recommends
"1.17+"), and `mix format` output differs across Elixir versions —
whichever host commits last "wins" formatting-wise and silently
un-formats every other host's next check.

Per core-directives.md's "two or more genuinely equivalent options"
clause, there are at least three live options here with no way for an
agent to infer the right one from `docs/requirements.yaml` or existing
decision records:

- (a) Pin one canonical Elixir/Mix version repo-wide via `.tool-versions`
  + asdf, enforced in CI.
- (b) Pin via `mix.exs`'s `elixir:` requirement plus a documented
  convention (no `.tool-versions`, just a written rule + CI check).
- (c) Keep resolving drift incident-by-incident as it recurs (status
  quo — what ISS-0008 and now ISS-0068 both did).

This design does **not** pick one. The follow-on action is to file
`docs/migration/decisions/0005-pin-formatting-toolchain.md` as a decision
draft naming these options, and to raise a new `docs/requirements.yaml`
or `docs/issues/` entry to track the durable fix — separate from
ISS-0068, whose own fix is fully covered by section 1 above. Not
executed as part of this design or this issue's fix.

## Open questions

None blocking ISS-0068's own fix. The toolchain-pinning choice (section
3) is the only open question, and it is explicitly deferred to a
decision record rather than resolved here.
