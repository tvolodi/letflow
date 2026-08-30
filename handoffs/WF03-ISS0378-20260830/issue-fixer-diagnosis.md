# ISSUE-FIXER Diagnosis — ISS-0378

**Run:** WF03-ISS0378-20260830
**Files read:** `test/letflow/scheduler/poller_test.exs` (full, esp. lines 1-25 and 329-360),
`test/specs/REQ-186.md` (full), `docs/requirements.yaml` REQ-186 entry, `git blame`,
`docs/anti-patterns.md` (the two directly relevant entries, quoted below), and
`test/letflow/scheduler_req188_test.exs` (found via grep while checking for recurrence).

## Step 0.5 — registry lookup

`docs/anti-patterns.md` already documents two closely related, already-resolved entries:

1. **"A test embeds `git diff main...HEAD` directly, assuming a local `main` branch
   always exists"** (REQ-165's `plugin_interface.ex` incident) — mitigation shipped was
   the defensive `Enum.find(["origin/main", "main"], ...)` ref-resolution helper. The
   poller test **already uses this exact helper** (`resolve_base_ref!/0`, lines 329-337)
   — so REQ-186's author clearly knew of and applied that specific mitigation. This is
   not a recurrence of *that* defect.
2. **"A test scoped to one specific historical commit SHA breaks the moment that commit
   is squash-merged away"** (REQ-176's `dlq_test.exs` AC6 incident) — this entry's
   mitigation is the one actually on point: *"Never write a test whose assertion depends
   on one specific commit surviving history rewrites... If the intent is 'the PR that
   implemented X didn't also add a route/controller,' prove it structurally instead —
   check the current working tree for the file/pattern that shouldn't exist... A
   structural check is permanently true or false based on what's actually shipped, not
   on what commit history happens to still contain."*

ISS-0378 is a **new instance of the same underlying class** as entry 2 (a test asserting
a permanent property by diffing against a moving ref/history, when a structural check of
the shipped artifact would do), even though the specific failure mode here (diffing
against `origin/main`/`main` rather than a hardcoded SHA) is closer in mechanics to entry
1. No prior `docs/issues/*.yaml` entry matches this exact symptom (checked for
"application.ex", "zero diff", "poller" — none found), so this is filed fresh, not a
recurrence of a previously *closed* issue. Severity stays MINOR (as filed) — not a
regression, a pre-existing latent defect newly tripped by legitimate work.

## Step 1 — Diagnosis

### What AC7 actually is, and what this test actually checks

REQ-186's real, documented acceptance criteria live in `docs/requirements.yaml` (10 items)
and are mapped 1:1 in `test/specs/REQ-186.md` (AC1–AC10). **The real "AC7"** (both in
`docs/requirements.yaml` and `test/specs/REQ-186.md`) is entirely unrelated to
`application.ex`:

> "a timer reaching the configured max fire retries transitions to `'failed'` with
> `failed_at` set and produces exactly one `dlq_entries` row with `entry_type "timer"`...
> and is not attempted again by subsequent polls" — covered by
> `test/letflow/scheduler_test.exs:"AC7: ..."`.

The property "no route or controller file is added or modified" is **AC9**, not AC7, and
`test/specs/REQ-186.md`'s own AC9 write-up is explicit that it must be checked
*structurally* (`File.exists?`/`Path.wildcard` over the actual `lib/letflow/api/`,
`lib/letflow/routers/`, `web/` trees) "**avoiding the hardcoded-SHA/squash-merge
fragility `test/letflow/dlq_test.exs`'s own AC6 test comment documents as this project's
anti-pattern**" — i.e. AC9 was written *with the anti-pattern-doc mitigation already
in mind*, and is implemented correctly in `test/letflow/scheduler_test.exs`.

The test at `poller_test.exs:340`, under `describe "AC7: retention runs on Poller's own
process -- no second ticker, application.ex untouched"`, is a **third, undocumented
test that appears nowhere in `docs/requirements.yaml`'s 10 acceptance criteria and
nowhere in `test/specs/REQ-186.md`'s AC1–AC10 coverage list.** It was not required by
the requirement, is not traceable to any AC, and directly re-introduces — one test
below the fix for it in the same requirement's own coverage doc — exactly the
"prove a permanent property via `git diff` against a moving ref" shape the anti-patterns
doc already says to avoid, this time diffing against **whatever `origin/main`/`main`
currently resolves to at test-run time** rather than a fixed historical commit. That
makes it strictly worse than the SHA-pinned version: it doesn't just break once when a
specific commit is squash-merged away, it breaks **every single time `main` gains any
future, legitimate, independently-reviewed commit that touches `application.ex` for any
reason** — which is exactly what happened when REQ-190 (already passed by
SECURITY-REVIEWER and REVIEWER on its own merits) added a `:logger` primary filter
registration there.

The sibling test in the same `describe` block — `"lib/letflow/scheduler/ contains
exactly one GenServer module (Poller) -- no second ticker"` — is the one **structural**
check in this describe block, and it is fine: it inspects the shipped `lib/letflow/
scheduler/**/*.ex` files directly, matching the AC9-style pattern, and needs no change.

### Root cause

`test/letflow/scheduler/poller_test.exs:339-352`'s `"lib/letflow/application.ex has zero
diff against the base branch"` test encodes a **point-in-time fact** ("as of REQ-186's
merge, `application.ex` happens to be untouched by this diff") as if it were a **standing
repo-wide invariant** ("`application.ex` must never change again, ever, for any future
reason"). It does this via `git diff --stat #{base_ref}...HEAD -- lib/letflow/
application.ex` where `base_ref` resolves to **whatever `origin/main`/`main` currently
is**, not the merge-base at the time REQ-186 was authored. Every later branch that
legitimately touches `application.ex` — regardless of how well-reviewed, however
unrelated to REQ-186's own scope, however far in the future — will fail this assertion
forever, because the check has no way to distinguish "REQ-186's own commits didn't touch
this file" (the actual, narrow, one-time thing worth proving during REQ-186's own
review) from "no commit anywhere, ever, may touch this file" (an invariant nobody
actually decided and that isn't in REQ-186's acceptance criteria at all).

**Why existing tests/gates didn't catch this at design time:** `test/specs/REQ-186.md`'s
own coverage checklist enumerates AC1–AC9 with one test case each and does not list this
test at all — it was added without a corresponding entry in the coverage matrix, so
TEST-DESIGN-VALIDATOR's job of matching every test to a claimed AC had nothing in the
matrix to catch this test being *extra*, undocumented, and mis-labeled ("AC7" when the
real AC7 is the max-fire-retries/DLQ property, already covered elsewhere in
`scheduler_test.exs`). The anti-patterns-doc mitigation for the *related* SHA-pinning
defect (`dlq_test.exs` AC6) was written **before** REQ-186 shipped this test (REQ-176
predates REQ-186), so the guidance existed in `docs/anti-patterns.md` at the time but was
not applied to this specific test.

### Confirmed via git blame

```
776372687 (Vladimir Titenko 2026-08-30 06:19:27 +0500 339) describe "AC7: retention runs on Poller's own process -- no second ticker, application.ex untouched" do
776372687 (Vladimir Titenko 2026-08-30 06:19:27 +0500 340)   test "lib/letflow/application.ex has zero diff against the base branch" do
...
```
All of lines 330-352 (the whole `resolve_base_ref!/0` helper plus both AC7-labeled
tests) trace to the single commit `77637268` — REQ-186's original implementation,
already on `main`. This is not something added later for a different reason, and it is
not a REQ-190 regression: REQ-190's `application.ex` change is a legitimate, independently
reviewed and approved diff that this pre-existing test was never designed to tolerate.

### Recurrence note (found while diagnosing, reported for a separate issue)

`test/letflow/scheduler_req188_test.exs:432-452` (REQ-188) contains the **identical
pattern** one file over: `describe "transition.ex is untouched by REQ-188"` /
`test "lib/letflow/engine/transition.ex has zero diff against the base branch"`, same
`resolve_base_ref!`-style inline helper, same `git diff --stat` against
`origin/main`/`main`, same "forever" framing. This is the same defect class and will trip
the same way the moment any future, legitimate change touches
`lib/letflow/engine/transition.ex`. **Out of scope for ISS-0378's fix** (different file,
different requirement, not what REQ-190 tripped), but this run is reporting it to ORCH
per "No Issue Left Local-Only" / "Unblock-Everything"'s scope boundary rather than fixing
it silently here or leaving it undocumented.

## Recommended fix (for CODE-DESIGNER — not implemented by this run)

**Delete** the `"lib/letflow/application.ex has zero diff against the base branch"` test
and its now-unused `resolve_base_ref!/0` helper from `poller_test.exs` entirely, rather
than narrowing it to a scoped diff. Rationale for deletion over narrowing:

- It maps to no acceptance criterion in `docs/requirements.yaml` or `test/specs/REQ-186.md`
  — there is nothing to preserve coverage of.
- The property it was informally gesturing at ("REQ-186 didn't add a second ticker /
  didn't need to touch the supervision tree") is **already covered structurally** by the
  sibling test in the same `describe` block (`lib/letflow/scheduler/` contains exactly
  one `GenServer` module) — that test is unaffected by this fix and needs no change.
- Per `docs/anti-patterns.md`'s own stated mitigation for this defect class: if a
  narrower structural property is actually wanted (e.g. "the poller's child spec is
  present and correctly configured in the supervision tree"), it should be written as a
  structural check against the **current shipped state** of `application.ex` (e.g.
  asserting `Letflow.Application.scheduler_children/0` — or whatever the real function is
  called — returns a child spec referencing `Letflow.Scheduler.Poller`), never as a
  `git diff` against a moving ref. CODE-DESIGNER should decide whether such a structural
  replacement test adds value beyond the existing GenServer-count test, or whether
  deletion alone is sufficient; either is consistent with this diagnosis, but a git-diff-
  based replacement of any kind is not.
- The `describe` block's title should also be corrected in the same change: it currently
  claims to be "AC7" when the actual AC7 (max-fire-retries → failed → DLQ) is already
  covered in `scheduler_test.exs`; if the GenServer-count test is kept as its own
  `describe`, it should be retitled to something that doesn't claim a specific AC number
  it was never mapped to in `test/specs/REQ-186.md`'s coverage checklist.

CODE-DESIGNER does not need to touch `test/letflow/scheduler_req188_test.exs` — that is
the separate, out-of-scope recurrence noted above and should be routed as its own issue.
