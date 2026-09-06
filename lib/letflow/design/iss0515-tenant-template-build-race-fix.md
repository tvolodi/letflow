# ISS-0515: eliminate the tenant_template build-race (structural pre-build fix)

Fixes the CI-reproducible failure diagnosed in
`handoffs/WF03-ISS0515-20260906/step-01-issue-fixer-diagnosis.json`. That
diagnosis is the authority for the reproduction evidence cited throughout
this document; this design does not re-derive it, only decides and specifies
the fix built on top of it.

## 0. Scope

Test-support only. No change to `Letflow.TenantProvisioning`, no change to
any file under `lib/letflow/` (other than none — this fix touches only
`test/test_helper.exs`), no change to REQ-226's own application code, no
change to `test/support/tenant_fixture.ex`'s public contract or behavior. The
only file this design asks ELIXIR-DEV to change is `test/test_helper.exs`
(one new statement plus a comment), and only to *add* a comment/rationale
note to `test/support/tenant_template.ex`'s existing `ensure_template!/0`
moduledoc describing the new caller (no logic change there — see §4).

## 1. Root cause recap (from the ISSUE-FIXER diagnosis, condensed)

`ensure_template!/0` (`test/support/tenant_template.ex:68-129`) serializes
concurrent first-time template builds with a session-level Postgres advisory
lock acquired via a bare `Repo.query!/2` call
(`tenant_template.ex:97`), subject to Ecto's default 15000ms client-side
query timeout (never overridden). When 2+ async test processes within one
`scripts/test_parallel.sh` partition (one partition = one Postgres database)
call `ensure_template!/0` for the first time before the node-global
`persistent_term` "already built" marker is set, all but one race for this
lock; every loser reliably (100% in direct reproduction, §4b/4c of the
diagnosis) hits the 15000ms client timeout and raises
`Postgrex.Error: query_canceled`, crashing that test with no retry
(`tenant_fixture.ex`'s documented one-shot contract, line 277).

The diagnosis additionally found (§4c/4d), but did NOT confirm, that waiters
inside the full `ensure_template!/0` flow were not observed to be granted the
lock promptly after the winner's release — unlike a clean, isolated
bare-lock hand-off — and flagged concurrent `Sandbox.mode(Repo, :auto)` calls
(`ensure_template!/0` line 82) as the leading, unconfirmed suspect.

## 2. Chosen direction: STRUCTURAL pre-build (option (a))

**Decision: pre-build `tenant_template` exactly once per partition process,
serially, before ExUnit ever dispatches a single test in that process.**
Option (b) (raise/remove the lock-acquisition timeout) is rejected — not
provisionally, but as a considered decision — for the reasons in §3.

This works because of one property of how `mix test` actually runs a suite,
verified by reading `ExUnit.start/1` and Mix's own test-invocation flow
rather than assumed: `ExUnit.start/1` registers ExUnit's real test run via a
`System.at_exit/1` callback — the callback that Elixir invokes only after
`elixir`/Mix's script-loading phase for the whole invocation (all of
`test_helper.exs`, plus every test file Mix has already required) has
finished running to completion. No test process is spawned, and no test
dispatch begins, until every top-level statement in `test_helper.exs` itself
has returned. A synchronous, blocking call placed anywhere in
`test_helper.exs` — before or after the `ExUnit.start(...)` call itself,
since `ExUnit.start/1` only *registers* the eventual run, it does not
trigger it inline — is therefore guaranteed to complete before any test in
that OS process can possibly call `ensure_template!/0` concurrently with it,
or with each other.

Consequently the fix does not merely widen the race's timing margin (as a
larger timeout would, per §3) — it removes the race's own precondition
(2+ concurrent first-callers) outright, for every partition, unconditionally.

## 3. Why NOT option (b) (raise the lock-acquisition timeout)

Rejected for two independent reasons, either one sufficient on its own:

1. **The diagnosis's §4c/4d finding is not resolved by a bigger number.**
   §4c showed waiters remaining un-granted the lock ~12s past the winner's
   own release *inside the full `ensure_template!/0` flow*, while §4d's
   otherwise-identical bare-lock probe (no `Sandbox.mode/2` calls, no build
   work) hands off promptly. If the `Sandbox.mode(Repo, :auto)`-concurrency
   theory is the real blocker, raising the timeout from 15000ms to
   `:infinity` does not fix anything — it converts a loud, fast,
   diagnosable `query_canceled` failure into tests that simply hang for the
   life of the test run (or until ExUnit's own test-level timeout fires,
   which is a *worse* failure mode: a hang gives far less diagnostic signal
   than today's exact-match Postgres error, and blocks the whole partition's
   forward progress rather than failing one test). Shipping option (b)
   would require first designing and running a dedicated repro that adds
   `Sandbox.mode/2` calls back into the §4d isolated probe to confirm or
   refute that theory — extra design/verification work option (a) does not
   need, because it makes the theory moot (see §6).
2. **Even if a larger timeout would work, it only re-derives the SAME
   concurrency window on every subsequent CI run** — any future growth in
   the number of tenant-fixture-needing test modules (exactly what tipped
   REQ-226 from "rare flake" to "100% reproducible" per the diagnosis's
   root-cause paragraph) widens the pool of concurrent first-callers again.
   A structural fix that removes concurrent first-callers entirely does not
   have this recurrence property; a bigger timeout does.

## 4. Exact hook placement

**File: `test/test_helper.exs`.** Add one call,
`Letflow.Test.TenantTemplate.ensure_template!()`, as a synchronous top-level
statement in that file. Recommended position: immediately after the existing
`ExUnit.start(exclude: [...])` call and before the `ExUnit.after_suite(fn
... end)` registration that follows it — matching this file's own existing
convention of grouping "things that must happen once, synchronously, at
suite-load time" near the top of the file (the two existing
`Letflow.TenantSchemaReaper.sweep_*` calls) separately from the
`ExUnit.start/1`/`ExUnit.after_suite/1` machinery. Placement relative to
`ExUnit.start/1` is not load-bearing for correctness (§2's guarantee holds
either way, since `ExUnit.start/1` only registers the run), but placing it
after keeps `test_helper.exs` readable top-to-bottom as "configure exclusions
→ register the run → do one-time pre-suite setup work" and avoids any reader
wondering whether the pre-build call could itself be an ExUnit test-adjacent
hook that needs `ExUnit.start/1` to have already run (it does not need that,
but placing it after removes the question).

Do not gate this call behind any test-path/file-selection heuristic (e.g.
"only if some test needing a tenant fixture is about to run"). §7 records why
this was considered and rejected.

### Why this file, and not some other hook point

- `test/test_helper.exs` is the single call site every invocation shape this
  project uses already shares — confirmed by that file's own existing
  ISS-0414 comment: "plain `mix test`, `mix test <path>`,
  `scripts/test_parallel.sh`, `mix letflow.check.test` already loads [it]".
  A hook placed here needs no per-invocation-shape special-casing.
- **Per-partition, not cross-partition, scope — and that is correct, not a
  gap.** `scripts/test_parallel.sh` launches N separate `mix test` OS
  processes (`MIX_TEST_PARTITION=<i> mix test --partitions N`), each its own
  BEAM VM, each pointed (via `config/test.exs`'s
  `database: "letflow_test#{MIX_TEST_PARTITION}"`) at its own, separate
  Postgres database. Every partition's own `test_helper.exs` load runs this
  pre-build call independently, once, serially, in that partition's own
  process, against that partition's own database. This is sufficient
  because the race the diagnosis reproduced (§3 of the diagnosis) is itself
  bounded to within one partition — advisory locks are per-database, so
  cross-partition contention on this lock was already structurally
  impossible before this fix, and remains so after it. No cross-partition
  coordination (a file lock, a leader-election scheme, a shared "first
  partition builds, others wait" protocol) is needed or should be added —
  that would be solving a race that does not exist, at real complexity cost.
- The two isolated subprocess runs `mix letflow.check.test` also launches
  (`mix test --only wasm_hang`, `mix test --only lua_wallclock_race`,
  `letflow.check.test.ex:328`/`:362`) are themselves separate `mix test`
  invocations and therefore load `test/test_helper.exs` independently too —
  they get the same one-time pre-build, paid once each, same as any other
  invocation. No special-casing needed for them either.

### Interaction with `tenant_fixture.ex`'s one-shot/no-retry contract

Preserved exactly, by construction, not by any change to that contract's own
code:

- After the pre-build hook completes, `Letflow.Test.TenantTemplate.template_ready?/0`
  returns `true` for the remainder of that partition process's life (the
  `persistent_term` marker set by `ensure_template!/0`'s existing final
  statement, `tenant_template.ex:126`, is exactly what makes this true).
- Every real test's own call into `ensure_template!/0` — reached via
  `TenantFixture.provision_schema!(:clone, tenant_id)` at
  `tenant_fixture.ex:356` — therefore always takes the existing fast path
  (`tenant_template.ex:84-85`, `template_ready?() -> :ok`) for the rest of
  that partition's run: no lock acquisition, no build, no code path that
  could raise `query_canceled` for the reason ISS-0515 describes, ever
  reached again in that process.
- `tenant_fixture.ex`'s own one-shot/no-retry documentation (line 277) is
  about `capture_schema_state/1`'s per-field-degrade contract on a
  *provisioning failure* — a different, unrelated concern this design does
  not touch. Nothing about the pre-build hook adds, removes, or reinterprets
  a retry anywhere in `tenant_fixture.ex`.

## 5. Preserving the atomic build-then-rename design

No change to `build_template!/0`/`do_build_template!/1`
(`tenant_template.ex:268-338`) or to INV-8 (a same-named, half-built
`"tenant_template"` is structurally impossible to produce — the rename to
the literal name is the last statement of a successful build, per that
function's own existing comment). The pre-build hook is purely a NEW,
single, early CALLER of the existing, unmodified `ensure_template!/0` public
function — it introduces no second code path, no alternate build sequence,
and no weakening of the existing staging-schema/rename-as-commit-point
design. If the pre-build call itself raises (a genuine build failure, not a
race artifact — see §6), `do_build_template!/1`'s existing rescue/cleanup
(`tenant_template.ex:284-295`) still drops the half-built staging schema
exactly as it does today; `"tenant_template"` still never exists under its
literal name in that failure case.

## 6. Resolution of the flagged Sandbox.mode/2 interaction (§4d of the diagnosis)

**Explicitly not independently confirmed or refuted by this design** — and
that is fine, because this fix makes it irrelevant to ISS-0515's actual
failure mode, rather than depending on its answer. The theory only mattered
for evaluating whether option (b) (raise the timeout) would work: a bigger
timeout is only safe if waiters are eventually granted the lock in bounded
time, which is exactly what §4c/§4d left open. This design does not choose
(b), so it does not need that theory settled — with the pre-build hook in
place, `ensure_template!/0`'s lock-acquisition line
(`tenant_template.ex:97`) is only ever reached by a SINGLE caller per
partition (the pre-build call itself, running alone, before any test process
exists to contend with it), so the advisory lock is always acquired
uncontested. There are no waiters for the `Sandbox.mode/2`-concurrency
theory to ever apply to, in the normal suite-run path this fix protects.

This is recorded here as a decision, not a silently dropped question:
**do not treat this design as having proven or disproven the
`Sandbox.mode/2` theory.** If a future change ever reintroduces a second
caller racing `ensure_template!/0`'s lock within one partition (see §7's
"what could reintroduce the race" list), that theory becomes load-bearing
again and must be resolved on its own before trusting any timeout-based
mitigation.

## 7. What could reintroduce the race, and why none of it applies today

Checked directly against the current test suite (not assumed):

- **Does any test ever drop the literal `"tenant_template"` schema and
  expect a from-scratch rebuild?** No. `grep` over `test/` for
  `DROP SCHEMA .* "tenant_template"` (the literal name, not a randomized
  staging/reference name) finds no matches. `test/support/tenant_template_test.exs`
  — the one file that exercises `ensure_template!/0`'s build machinery most
  directly — only ever drops its OWN randomized staging/reference schemas
  (`generate_staging_schema_name/0` output), never `"tenant_template"`
  itself, and is `async: false`. So nothing in today's suite ever un-builds
  the template mid-run, which is what would be required to make a SECOND
  genuine build attempt (as opposed to the harmless fast path) reachable
  after the pre-build hook has already run once.
- **Could a future test add such a drop-and-rebuild case?** If one is ever
  added, it must NOT be `async: true` relative to any other test that also
  calls `ensure_template!/0`/`clone_tenant_schema!/1` (this is already
  `tenant_template_test.exs`'s own stated rule for itself, in its own
  moduledoc) — that existing rule is exactly what continues to prevent a
  reintroduced race, independent of this fix. This design does not change or
  weaken that rule; it is noted here so a future reader does not assume the
  pre-build hook makes every future test "float free" of the concurrency
  discipline `tenant_template.ex`'s design already requires.
- **Should the pre-build call be conditional (skip it for a test run that
  provably touches no tenant fixture)?** Considered and rejected: any such
  heuristic (path-based, tag-based, static-analysis-based) is a NEW piece of
  machinery that itself needs to be kept correct as the suite grows, in
  exchange for saving ~1.8-1.9s (the diagnosis's own measured from-scratch
  build time, §4a) on the minority of invocations that touch no tenant
  fixture at all. The correctness win (100% elimination of a
  100%-reproducing, whole-CI-gate-blocking failure) is not worth trading
  for that marginal, invocation-dependent saving, and unconditional
  behavior is far easier for a future reader to reason about than
  conditional behavior tied to which test files happen to be selected.

## 8. Verification ELIXIR-DEV must perform before considering this done

Re-run, not merely re-read, the diagnosis's own reproduction, against the
post-fix code:

1. **Direct re-run of diagnosis §4b's concurrency reproduction.** Drop
   `tenant_template` (`DROP SCHEMA tenant_template CASCADE`), then launch 5
   concurrent `Task.async` callers of `Letflow.Test.TenantTemplate.ensure_template!/0`
   against the same database/pool, exactly as the diagnosis did — but this
   time AFTER first invoking the new `test/test_helper.exs`-driven pre-build
   path (i.e. run this as a follow-up statement inside the same `mix run -e`
   session, calling `ensure_template!/0` once first to simulate the
   pre-build hook, THEN launching the 5 concurrent callers) and confirm all
   5 return `:ok` immediately via the fast path (`template_ready?/0` already
   `true`), not via a fresh lock acquisition. This directly demonstrates the
   mechanism §2 relies on: once pre-built, concurrent callers never reach
   the lock at all.
2. **Real partitioned suite run.** Run `mix letflow.check.test` (or
   `scripts/test_parallel.sh` directly) end to end at least twice
   consecutively and confirm zero occurrences of
   `Postgrex.Error: ERROR 57014 (query_canceled)` or
   `TENANT_TEMPLATE_BUILD_FAILED` in any partition's log — the diagnosis's
   own byte-for-byte failure signature (ISS-0515's filed Postgres-log
   excerpt). A single clean run is not sufficient evidence given the
   diagnosis's own note that the pre-fix race was itself deterministic, not
   a rare flake — two consecutive clean runs against the SAME REQ-226 branch
   commit that previously failed reproducibly (per ISS-0515's own filing:
   "run 2, a plain rerun of the identical commit" also failed) is the
   comparable bar.
3. **Timing sanity check.** Confirm the added per-invocation cost is close
   to the diagnosis's own measured ~1.8-1.9s per partition process (not, say,
   16x that if `TEST_POOL_SIZE` clamping under high `N` makes replay slower
   under contention) — report the actual measured added wall-clock cost
   per partition in the implementation handoff, so a future reader has a
   real number rather than an assumption.
4. **Confirm no regression in `test/support/tenant_template_test.exs`
   itself** (`mix test test/support/tenant_template_test.exs`) — this file's
   own tests call `ensure_template!/0` expecting the existing fast-path/
   already-built behavior in most cases (§7 above), so it is the most
   direct existing regression check for "the pre-build hook didn't change
   `ensure_template!/0`'s own observable behavior for any existing caller."

If step 1 or 2 does not come back clean, the `Sandbox.mode/2` theory from
§6 becomes relevant again — do not proceed to declare the fix complete on
partial evidence; escalate back through CODE-DESIGN-VALIDATOR/ORCH with the
actual failure output rather than assuming a variant of this same hook
placement will fix it.

## 9. Open questions

None outstanding for this fix's own scope. The `Sandbox.mode/2` concurrency
theory (§6) remains genuinely unresolved as a general fact about
`ensure_template!/0`'s lock-acquisition behavior under contention, but is
explicitly out of this design's scope to resolve, since the chosen fix does
not depend on its answer (see §6's closing note for exactly when it would
need to be revisited).
