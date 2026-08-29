# TEST-DESIGN-VALIDATOR report — REQ-181, Step 3b

**Verdict: PASS**

## What was checked

Read directly, in full: `test/letflow/webhooks_test.exs` (14 tests),
`test/specs/REQ-181.md`, `handoffs/WF02-REQ181-20260829/step-01-code-designer.json`
(original acceptance criteria, verified against `docs/requirements.yaml`'s REQ-181
entry's phrasing), `handoffs/WF02-REQ181-20260829/step-03b-test-design-validator.json`,
and `lib/letflow/webhooks.ex` / `lib/letflow/webhooks/subscription.ex`.

## Acceptance-criterion coverage (independently re-derived, not copied from the spec's
own checklist)

- **AC1** (schema-per-tenant, `tenant_id` retained) — covered by the AC1 describe block:
  queries `information_schema.columns`/`information_schema.tables` against a real
  provisioned tenant schema and against `public`. Verifies the migration's actual
  runtime effect, not its source text. Real coverage.
- **AC2** (generate-once secret, hash-only storage, never re-exposed) — two tests:
  one independently recomputes the SHA-256 hash of the returned plaintext and compares
  to the persisted `secret_hash` (re-selected from Postgres, not the in-memory struct),
  asserting `secret_hash != plaintext`; the other confirms `list/1`'s returned struct
  has no `hmac_secret_once` key and the hash matches. Both explicit tests the AC calls
  for are present. Real coverage.
- **AC3** (`update/3` status/is_active reconciliation) — 7 tests covering both single
  keys, both agreeing pairs, the disagreeing-pair error path (with a re-select proving
  no write happened), and the reverse pause->resume path clearing `paused_at`. This is
  more thorough than the AC's literal two-test minimum. Real coverage.
- **AC4** (list/1 tenant-scoped) — provisions two real tenant schemas, creates under
  one, asserts absence from the other. Real coverage.
- **AC5** (delete/2 removes row; second delete not-found) — single test, both halves in
  sequence, matching the AC's own phrasing. Real coverage.
- **AC6** (no route/controller file) — two tests: source-text check on both new files
  for Plug/Router/controller/route constructs, and a directory listing of
  `lib/letflow/routers` for any webhook-named file. Real, working-tree-based coverage
  (arguably stronger than the AC's stated `git diff --stat` approach, and still
  satisfies its intent).

No `@tag :skip` anywhere in the file. No "TODO: implement" language. No test depends on
another test having run first — every test calls `provisioned_tenant!/1` itself and
builds its own subscription via `create!/2`; no shared mutable fixture state across
tests (confirmed by reading all 14 test bodies in full above). No hardcoded secrets or
connection strings — the target URL is a literal `https://example.test/hook` placeholder
carrying no credential, and the DB connection comes from `Letflow.DataCase`/config, not
a literal in this file.

## Fresh test run (this session, not copied from TEST-DESIGNER's report)

```
$ mix test test/letflow/webhooks_test.exs
..............
Finished in 9.6 seconds (0.00s async, 9.6s sync)
Result: 14 passed
```

Matches TEST-DESIGNER's reported `14 passed`.

## The disclosed gap: row-lock (`lock("FOR UPDATE")` in `fetch_and_lock_subscription/3`)
mutation not caught

TEST-DESIGNER disclosed, rather than hid, that removing the `FOR UPDATE` clause from
`update/3`'s row-lock step left the suite at 14/14 passed — i.e. no test exercises
concurrent `update/3` calls against the same row, so the lock's actual purpose
(preventing a lost-update race) is unverified here.

**This is not the WF-03 "pre-fix failure is code-did-not-exist" exception path** — this
is a WF-02 new-feature test-design gate, so that rule (mandatory mutant re-application by
me) does not apply here. The applicable question is the ordinary TEST-DESIGN-VALIDATOR
bar: does every AC have real coverage, with no undisclosed gaps. None of REQ-181's six
ACs (verified against `docs/requirements.yaml`'s REQ-181 entry and the Step-01 handoff)
mentions concurrent-update behavior or lock contention at all — the row lock is an
internal robustness mechanism the design carried over from REQ-176's precedent, not an
acceptance criterion in its own right. A disclosed, non-AC-covering gap is weighed, not
auto-failed.

**Precedent check, as instructed** — grepped `test/letflow/dlq_test.exs` and
`test/specs/REQ-176.md` for a concurrent-lock test: none exists. `lib/letflow/dlq.ex`'s
`fetch_and_lock_entry/3` (line 300-307) uses the identical `lock("FOR UPDATE")` idiom
that `lib/letflow/webhooks.ex`'s `fetch_and_lock_subscription/3` (line 304-307) now
reuses verbatim. Read `handoffs/WF02-REQ176-20260829/step-03b-test-design-validator.json`
in full: its task explicitly named only three mutants for independent re-verification
(#2 tenant-scoping drop, #6 cursor-boundary duplication, #3/#4 status-guard removal) out
of TEST-DESIGNER's 8 documented mutants for `Letflow.Dlq` — a lock-removal mutant was
never in TEST-DESIGNER's list for Dlq and was never demanded by TEST-DESIGN-VALIDATOR.
REQ-176 passed TEST-DESIGN-VALIDATOR, TEST-RUNNER, and RELEASE-VALIDATOR (per
`handoffs/registry.json`'s REQ-176 entry and `docs/requirements.yaml`'s `status: done`)
with this exact class of gap present and never closed. No issue was ever filed against
Dlq for it either (`docs/issues/ISS-0353.yaml`, the one issue REVIEWER filed against
`Letflow.Dlq`, is about the changeset's cast list, unrelated to locking). Separately,
`Letflow.Dlq`'s concurrency safety for this idiom was reviewed and passed by
SECURITY-REVIEWER via code reading, per `handoffs/registry.json`'s REQ-176 note
("verified tenant_id derivation/ILIKE parameterization/concurrency safety by reading
real code") — i.e. this codebase's established path for validating a row-lock's
correctness is SECURITY-REVIEWER/REVIEWER code-reading, not a TEST-DESIGNER concurrent
test, and REQ-181 already passed both of those gates (commit `5337911`).

Note also (for context, not as a reason to require anything here): this codebase does
have proven capability to write genuine concurrent-process lock-contention tests when an
AC specifically calls for it — `test/letflow/engine/reconstruction_test.exs`'s
`with_locked_projection/3` tests (referenced in `docs/issues/ISS-0113.yaml`) spawn a
separate process holding a real `FOR UPDATE` lock. That precedent shows the gap is
closable, not that it must be closed here — no REQ-181 acceptance criterion calls for it,
and the sibling module shipped without it.

**Decision: accept the gap as a disclosed, non-blocking follow-up**, consistent with
REQ-176/177's precedent for the identical idiom, rather than inventing a stricter bar for
REQ-181 alone. Recommend (non-blocking, for ORCH/queue) filing a queued follow-up issue
covering both `Letflow.Dlq` and `Letflow.Webhooks`' `update`/`retry`/`discard` lock paths
together, since it is the same gap in two modules and would be more coherent fixed once
than twice — this is a recommendation, not a condition of this PASS.

## Result

PASS. Route to TEST-RUNNER.
