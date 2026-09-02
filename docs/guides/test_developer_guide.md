# Letflow — Test Developer Guide

**Audience:** `TEST-DESIGNER`, `TEST-DESIGN-VALIDATOR`, `TEST-RUNNER`, `ISSUE-FIXER`.

---

## 1. Test philosophy

### Core testing directives

> These take precedence over every other rule in this guide. A handoff violating either
> MUST be marked FAILED, not PASS.

**DIRECTIVE T-1 — No mocked database.** Tests run against a real PostgreSQL database
via `Letflow.DataCase` (Ecto's sandboxed connection — real Postgres, transaction rolled
back per test, not a mock). No in-memory fake, no stubbed `Repo`. `@tag :skip` does not
constitute a passing test — a requirement whose test cases are entirely skipped stays
`in_progress`, not `done`.

**DIRECTIVE T-2 — No mocked HTTP for integration/UAT-level tests.** Where a test drives
the system through its HTTP surface (`Letflow.Router`) or `web/`'s integration against
it, it sends a real request to a real running server backed by a real database. Unit
tests of a single pure function are the exception — those legitimately test one
function in isolation without a server.

### Additional principles

1. **Pure functions first.** Anything with no I/O (a transition-legality check, a
   validation function) gets a direct unit test before integration-level testing.
2. **Tests are specifications.** Every acceptance criterion has at least one test that
   would fail if the criterion were violated — not just "a test exists near this code."
3. **Deterministic only.** No dependency on wall-clock time or unseeded randomness.
   `StreamData` properties use the framework's own seeding, not a hand-rolled RNG.
4. **No test pollution.** Each test creates its own data (see `Ecto.UUID.generate()` in
   the existing tests) and doesn't depend on execution order.
5. **`service_catalog` has no tenant-schema cleanup fallback (ISS-0414).** Every other
   tenant-scoped table gets its rows reclaimed for free when a test's `on_exit/1` drops
   that test's whole tenant schema (`DROP SCHEMA ... CASCADE`). `service_catalog` is a
   GLOBAL table (`Letflow.ServiceCatalog`'s own moduledoc) with no such fallback — a row
   left behind is left behind for good until something explicitly deletes it. Every test
   file that writes to `service_catalog` must still clean up its own rows in its own
   `on_exit/1` (see `test/letflow/service_catalog_test.exs`'s `cleanup_entry!/1`). The
   suite-boundary safety net `Letflow.TenantSchemaReaper.sweep_service_catalog_orphans/1`
   adds (`test/test_helper.exs`, before `ExUnit.start()` and in `ExUnit.after_suite/1`)
   is exactly that — a safety net for a *crashed* run whose `on_exit/1` never got to run
   — not a substitute for correct per-test cleanup in a normally-completing one: finding
   any row at all at a suite boundary is itself logged as an anomaly, so a test relying
   on the reaper instead of its own `on_exit/1` would trigger that warning on every
   normal run.

---

## 2. Test layer hierarchy (as it exists today — this grows with the stages)

```
HTTP/integration tests (ExUnit, real Plug.Test or real running server + real Postgres)
  └── test/letflow/*_test.exs exercising Letflow.Router end to end (see REQ-107's
      precedent) — coverage target: every documented HTTP endpoint

Property tests (ExUnit + StreamData)
  └── Standing in for what static typing would catch for free — see
      test/letflow/process_instance_test.exs's `no sequence of actions produces an
      invalid state`. Use this pattern whenever a module has a closed set of legal
      states/transitions: generate a random sequence of actions, assert the invariant
      holds regardless of the sequence, not just for one hand-picked happy path.

Unit/example tests (ExUnit)
  └── One test per acceptance criterion, direct example-based assertions — see the
      happy-path and illegal-transition tests in process_instance_test.exs
```

There is no dedicated frontend unit-test layer yet — `web/` is an integration boundary
(§ `docs/guides/frontend_developer_guide.md`), not a codebase Letflow's own test suite
covers. If S8 requirements later need frontend-side test coverage, that's scoped then,
not assumed now.

---

## 3. Test spec format

`TEST-DESIGNER` writes `test/specs/<REQ-ID>.md` before/alongside test code:

```markdown
# Test Spec: <REQ-ID> — <short name>

**Requirement:** <REQ-ID> — verbatim acceptance criteria from docs/requirements.yaml
**Test tier:** unit | unit+integration | unit+integration+property

## Test cases

1. <what this case proves> — see test/letflow/<file>.exs:<test name>
2. ...

## Coverage check

- [ ] Every acceptance criterion above has ≥1 test case listed
- [ ] If this touches a closed state/transition set: a property test covers it, not
      just example cases
```

---

## 4. Writing a state-machine test — follow the existing pattern exactly

For any module shaped like `Letflow.ProcessInstance` (named states, legal/illegal
transitions), write, in this order:

1. A happy-path example test (one legal sequence, asserting each intermediate state).
2. An illegal-transition test (assert the action is rejected with
   `{:error, {:invalid_transition, action, state}}`, and that state didn't change).
3. A persistence test (assert the transition was actually written to Postgres — query
   it back, don't just trust the in-memory reply).
4. A property test using `ExUnitProperties`/`StreamData`, generating random action
   sequences and asserting the instance never leaves the known state set — see
   `test/letflow/process_instance_test.exs`'s `action_generator/0` and the property
   itself for the exact shape to copy.
5. If the module manages a supervised process: a crash-isolation test (kill one
   instance's process, assert a sibling instance's state is untouched) — see
   `test/letflow/parallel_approval_test.exs`.

---

## 5. Regression tests (WF-03)

A test written to prove a bug fix must be shown to **fail against the pre-fix code**.
State this explicitly in the test spec. If you can cheaply check out the pre-fix commit
and confirm the new test fails there, do so — a test that only ever ran against
already-fixed code proves nothing about whether it actually covers the bug.

---

## 6. No local toolchain?

Use the Docker fallback in `docs/anti-patterns.md` before reporting "can't verify" —
see `docs/guides/backend_developer_guide.md` §7 for the exact procedure. It has
produced clean, verifiable `mix test` output before (12/12 tests, including the
property test, against a real Postgres container).

---

## 7. Reporting

`TEST-RUNNER` writes `test/reports/report-<date>-<run-id>.yaml` with the actual output
(pass/fail counts, property-test seeds if a property failed, wall-clock duration) —
never a paraphrase like "tests passed." `RELEASE-VALIDATOR` independently re-runs the
suite rather than trusting this report alone (see `core-directives.md`), so an honest,
complete report matters more than a persuasive one.
