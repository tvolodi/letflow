# Design: ISS-0716 — `ColumnPromotionTest` AC1's `:all`-scoped assertion is flaky under concurrent real-commit tenants

**Run:** fix/WF03-ISS0716-20260918 (GH-1534, queue Q-716) · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR.

**Scope: TEST FILE ONLY.** One change, to
`test/letflow/tenant_provisioning/column_promotion_test.exs`'s AC1 test (lines 171–201, the
`describe "AC1 -- DDL applied to every tenant, verified directly against Postgres"` block). No
`lib/letflow/` file, no `priv/repo/migrations/*`, no `config/*.exs` is touched.

---

## 0. Sources read

- `docs/issues/ISS-0716.yaml` — the registered finding (TEST-RUNNER, `WF02-REQ370-20260918`,
  GH-1534/Q-716): a full-suite run observed 4 tenant ids where AC1 expects exactly 2
  (`[tenant_a, tenant_b]`), flagged as lower-confidence ("structural exposure, not a pinned
  external mechanism").
- `test/letflow/tenant_provisioning/column_promotion_test.exs`, read in full (1093 lines). AC1 is
  lines 171–201; the file's `provisioned_tenant/0` fixture is lines 57–97;
  `describe "AC2..."`'s two tests (lines 250–367) and every other `describe` block in the file
  reused as evidence of the file's own established patterns (`Enum.find/2` for per-tenant row
  lookup at lines 268–269, `[tenant_a, tenant_b]`-scoped — never `:all` — registration calls
  everywhere except AC1).
- `lib/letflow/tenant_provisioning.ex`: `register_column_promotion/4` (1218–1256, `@doc` at
  1198–1217), `resolve_tenant_ids/1` (1258–1259), `list_registrations/0` (274–276),
  `run_column_promotion/1` (1282–1307, `@spec` above 1282).
- `lib/letflow/design/iss0580-sandbox-auto-mode-restore-leak.md` — the prior design this issue's
  root cause is a residual, documented consequence of (§0.1's own root-cause language and its
  `Letflow.Test.SandboxAutoMode.provision!/2` helper, used by this file's `provisioned_tenant/0` at
  line 58 today, post-ISS-0580).
- `test/support/sandbox_auto_mode.ex` — confirms `provision!/2`'s contract: it forces `Repo`
  sandbox mode to `:auto` for the duration of `fun.()` (real Postgres DDL cannot run under
  `:manual`/`{:shared, self()}` mode), then restores `:manual` + a fresh checkout in an `after`
  block. While `:auto` is in effect, *every* concurrently-scheduled process sharing this pool
  connection also commits for real instead of rolling back — a documented, bounded, non-zero
  window (ISS-0580 design §0.1, §4 INV-1/INV-2), not a defect in that design itself.
- `test/support/data_case.ex` — confirms this file's `use Letflow.DataCase, async: false` still
  means *this test module's own tests* run serially relative to each other, but does not protect
  against `:auto`-mode windows opened by unrelated, concurrently-scheduled test processes in the
  same partition (ISS-0716's own root cause, not disputed here).

### 0.1 Root cause, re-derived and confirmed against actual code

1. `provisioned_tenant/0` (lines 57–97) wraps its provisioning work in
   `SandboxAutoMode.provision!(Letflow.Repo, fn -> ... end)`. For the short duration of each call,
   `Letflow.Repo`'s sandbox mode is global `:auto` — a pool-wide setting, not scoped to the calling
   process (ISS-0580 design §0.1). AC1's test (line 172) calls `provisioned_tenant()` **twice**
   (lines 173–174), so this window opens (at minimum) twice before AC1's own assertions run.
2. `register_column_promotion("invoice", "amount", %{...}, :all)` (lines 181–187) resolves `:all`
   via `resolve_tenant_ids(:all)` (tenant_provisioning.ex:1258), which calls
   `Enum.map(list_registrations(), & &1.tenant_id)` — and `list_registrations/0` (274–276) is
   `Repo.all(Registration)`, **unscoped**: every row in the `tenant_schemas` table at query time,
   for every tenant any process has provisioned and left committed, not just this test's own two.
3. This is exactly the documented, correct production contract for `:all`
   (tenant_provisioning.ex:1198–1206's own `@doc`: "`:all` resolves via `list_registrations/0` at
   call time") — a real production caller invoking `register_column_promotion(..., :all)` is
   *supposed* to pick up every tenant that exists, including ones provisioned moments earlier by
   an unrelated process. `list_registrations/0` and `resolve_tenant_ids/1` are not defective; they
   are doing their documented job.
4. AC1's own assertion (line 189–190) is what turns a correct production behavior into a flaky
   test:
   ```
   tenant_ids_registered = Enum.map(rows, & &1.tenant_id) |> Enum.sort()
   assert tenant_ids_registered == Enum.sort([tenant_a, tenant_b])
   ```
   This asserts **exact set equality** — that the `:all`-scoped call returns *precisely* the two
   tenants this test itself provisioned, and no others. Under the real-commit `:auto`-mode window
   described in step 1, any other test process in the same partition that happens to provision (and
   not yet have torn down) a tenant schema during that same window becomes a third or fourth row
   `list_registrations/0` returns — a row this test did not create and has no way to exclude by
   construction. TEST-RUNNER's observed 4-ids-instead-of-2 run is consistent with exactly this:
   two extra, unrelated tenants left visible by concurrently-scheduled provisioning.
5. Downstream, line 192's loop (`for row <- rows do ... run_column_promotion(row.id) ... end`)
   iterates **every** row `:all` resolved — including any such unrelated leaked tenant's row. If
   that unrelated tenant has no active `"invoice"` entity definition (a very plausible state for a
   tenant belonging to a *different* test file/scenario), `run_column_promotion/1`'s own
   `do_run_column_promotion/2` path (not modified by this design — see §2) would fail for that row
   for a reason entirely unrelated to AC1's own subject matter — producing a second, more confusing
   failure mode layered on top of the first (line 190's) one.

**Confirmed: ISSUE-FIXER's characterization is accurate.** No `lib/letflow/` change is warranted —
`register_column_promotion/4`, `resolve_tenant_ids/1`, and `list_registrations/0` all behave per
their documented, correct, in-use-by-real-callers contract. This is a test-assertion defect: AC1
encodes a stronger claim (exact-set) than `:all`'s own documented semantics can guarantee inside a
real-commit, non-sandboxed, concurrently-scheduled test suite. This is the same residual hazard
ISS-0580's design already named and left open (that design's §0.1: "leaking `:auto` mode... makes
every *other* `async: true` test's `Repo` writes... become real uncommitted-forever commits"; §7
OQ-1's framing of "bounded but nonzero window" for `engine_concurrency_test.exs` applies here in
the same spirit, for the six-file `provision!/2` case) — ISS-0580 shortened the window, it did not
(and, given `Ecto.Migrator`'s hard requirement for a real, non-sandboxed connection during
provisioning per `req022-tenant-schema-provisioning.md` §6, cannot) eliminate it. This design
accepts that residual window as a given, per this task's explicit framing, and instead makes AC1's
own assertion robust to it.

---

## 1. Fix — assertion shape, AC1 test only

### 1.1 Containment, not exact-set-equality (replaces lines 189–190)

Replace the current exact-equality assertion:

```
tenant_ids_registered = Enum.map(rows, & &1.tenant_id) |> Enum.sort()
assert tenant_ids_registered == Enum.sort([tenant_a, tenant_b])
```

with a **containment/subset** assertion: `tenant_a` and `tenant_b` must each be present among the
`tenant_id`s `rows` (equivalently, the ids `:all` resolved to) — without requiring that the
resolved set contains *only* those two. Concretely, in prose (no implementation code, per this
task's scope):

- Compute `tenant_ids_registered` exactly as today (`Enum.map(rows, & &1.tenant_id)` — the
  `Enum.sort/1` is no longer needed for this specific check since membership doesn't depend on
  order, but MAY be kept for readability/diagnostic-output stability; ELIXIR-DEV's call).
- Assert `tenant_a in tenant_ids_registered`.
- Assert `tenant_b in tenant_ids_registered`.
- Do **not** assert anything about the total count or the presence/absence of any other id in
  `tenant_ids_registered` — a third or fourth id from a concurrently-committed, unrelated tenant is
  an expected, tolerated possibility under `:all`'s own real semantics (§0.1 point 3), not a test
  failure.

This preserves AC1's actual substance — "registering with `:all` includes every currently-existing
tenant, in particular the two this test provisioned" — while dropping the untestable-under-this-
harness stronger claim ("and *only* those two") that the fixture's own documented `:auto`-mode
window (ISS-0580) cannot guarantee.

### 1.2 Scope the downstream DDL-execution loop to this test's own two rows (replaces line 192's iteration source)

Per §0.1 point 5: the `for row <- rows do ... run_column_promotion(row.id) ... end` loop (lines
192–195) must not run against rows belonging to tenants this test did not provision — doing so
risks a second, unrelated failure mode (an unrelated tenant's row failing
`run_column_promotion/1` for a reason having nothing to do with AC1, e.g. no active `"invoice"`
definition in that tenant's schema) that would make a future flake investigation *more* confusing,
not less.

**Decision (per this task's explicit instruction to decide, not leave open): scope the loop.**
Filter `rows` down to only the rows whose `tenant_id` is `tenant_a` or `tenant_b` before iterating,
and iterate that filtered list instead of the full `rows` returned by `register_column_promotion/4`.
In prose: `rows_for_this_test = Enum.filter(rows, &(&1.tenant_id in [tenant_a, tenant_b]))`, then
the existing loop body (`assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
TenantProvisioning.run_column_promotion(row.id)`) iterates `rows_for_this_test`, unchanged
otherwise.

Rationale for filtering here rather than, say, asserting `length(rows_for_this_test) == 2` and
stopping: AC1's own remaining assertions (lines 199–200) already independently verify the DDL
landed correctly in `schema_a` and `schema_b` specifically — the loop's only job is to *run* the
promotion for this test's own two tenants so those two schema-level assertions have something to
check. Running `run_column_promotion/1` against a leaked, unrelated tenant's row would (a) not
serve AC1's own purpose (that row's schema isn't checked by anything AC1 asserts), (b) risk a
spurious, confusing failure per §0.1 point 5, and (c) leave an unrelated `ColumnPromotion` row for
some other tenant transitioned to `ddl_applied` as an unintended side effect of this test — a
mutation this test has no business making. Filtering avoids all three.

Do assert `length(rows_for_this_test) == 2` (or equivalent) directly after the filter, as a
sharper, still-safe-under-concurrency check than exact-set-equality on the *unfiltered* `rows` —
this pins down that AC1's own two tenants are present exactly once each (not zero, not duplicated),
without saying anything about `rows`'s total size. This is a strictly stronger, still-flake-safe
replacement for the containment checks in §1.1's last bullet's "don't assert count" guidance —
resolve the two together as: no assertion on `length(rows)` (the full, unfiltered list), but assert
`length(rows_for_this_test) == 2` (the filtered list) immediately after computing it.

---

## 2. What is explicitly NOT changed

- **No `lib/letflow/tenant_provisioning.ex` change.** `register_column_promotion/4`,
  `resolve_tenant_ids/1`, `list_registrations/0`, and `run_column_promotion/1` all keep their
  current, documented behavior. Per ISSUE-FIXER's diagnosis and this task's own explicit framing:
  `:all`'s unscoped resolution is correct production behavior, used by real callers, and must not
  be scoped, filtered, or made tenant-aware as a side effect of fixing this test.
- **No `test/support/sandbox_auto_mode.ex` change.** ISS-0580's `provision!/2`/`enter_auto_mode!/1`/
  `exit_auto_mode!/1` contract is unchanged; this design does not attempt to further shrink or
  eliminate the `:auto`-mode window — that window, and its "other concurrently-scheduled tests may
  commit for real" consequence, is accepted as a known, bounded, residual hazard (ISS-0580 design
  §7 OQ-1's framing), not something this fix re-litigates.
- **No other `describe` block in this file.** Every other test that calls
  `register_column_promotion/4` already passes an explicit tenant-id list (`[tenant_id]` or
  `[tenant_a, tenant_b]`), never `:all` — AC1 is the file's only `:all`-scoped call, and the only
  test exposed to this flake. Confirmed by grep-equivalent read of every `register_column_promotion`
  call site in the file (lines 181, 229, 264, 318, 354, 382, 446, 471, 508, 550, 665, 725, 764, 859,
  905, 949, 994, 1026, 1065) — every one besides line 181 (AC1) passes a list, never the `:all`
  atom.
- **No change to `provisioned_tenant/0` itself** (lines 57–97) — still calls
  `SandboxAutoMode.provision!/2` exactly as today; AC1 still calls it twice (lines 173–174),
  unchanged.

---

## 3. Invariants

- **INV-1 — AC1 still proves its own named claim.** "DDL applied to every tenant `:all` resolves,
  verified directly against Postgres" remains verified: `tenant_a`'s and `tenant_b`'s presence in
  the `:all`-resolved set (§1.1), successful DDL execution for exactly those two rows (§1.2), and
  the two `fetch_information_schema_column/3` assertions against real Postgres (lines 199–200,
  unchanged) together still cover the full claim.
- **INV-2 — the test no longer fails on a correct, expected production behavior.** A third or
  fourth tenant id appearing in `:all`'s resolution (from a concurrently-committed, unrelated test)
  no longer fails AC1 — it is tolerated, per §1.1.
- **INV-3 — no unrelated tenant row is mutated by this test.** The DDL-execution loop only ever
  calls `run_column_promotion/1` for rows belonging to `tenant_a`/`tenant_b` (§1.2's filter) — a
  leaked, unrelated tenant's `ColumnPromotion` row is left exactly as `:all`'s registration step
  created it (`status: "pending"`), never advanced to `ddl_applied` by this test.
- **INV-4 — `:all`'s production contract is untouched.** No `lib/letflow/` file changes; a real
  caller of `register_column_promotion(..., :all)` continues to receive every currently-registered
  tenant, exactly as documented at tenant_provisioning.ex:1198–1206.
- **INV-5 — test-file-only scope.** Every change in this design lands in
  `test/letflow/tenant_provisioning/column_promotion_test.exs`'s AC1 test body only (lines
  171–201). No other file is touched.

---

## 4. Scope confirmation — not a SECURITY-REVIEWER gate

This is a test-assertion-only change to one `describe` block in one `*_test.exs` file. No API
route, migration, response shaping, or production secret/credential is touched; no `lib/letflow/`
file changes. Per this repo's own precedent (ISS-0580 design §6's identical reasoning, reused here
rather than re-derived), SECURITY-REVIEWER sign-off can be skipped unless CODE-DESIGN-VALIDATOR
disagrees.

---

## 5. Open questions

**OQ-1 — should AC1's containment check additionally assert that `rows_for_this_test`'s two rows'
`entity_type`/`attribute` match `"invoice"`/`"amount"`?** Not proposed here: `register_column_
promotion/4`'s own insert (`tenant_provisioning.ex:1238–1248`) always stamps the `entity_type`/
`attribute` arguments the call itself passed onto every row it creates, for every tenant — there is
no code path by which a row in `rows` could carry a different `entity_type`/`attribute` than what
AC1's own call requested (line 182–186 requests `"invoice"`/`"amount"` uniformly for all resolved
tenant ids). Adding this assertion would be redundant with `register_column_promotion/4`'s own,
already-covered contract, not a defense against anything AC1 is actually exposed to. Left out;
flagged here per this task's instruction not to silently resolve an open question by guessing —
this one is resolved (not left as a TBD), the answer is "no, out of scope," with the reasoning
shown rather than asserted by fiat.

**OQ-2 — is `length(rows_for_this_test) == 2` itself flake-safe?** Yes, by construction: it counts
only rows already filtered to `tenant_id in [tenant_a, tenant_b]` (§1.2), and
`register_column_promotion/4` creates exactly one row per resolved tenant id (one `Enum.map/2`
iteration per id, `tenant_provisioning.ex:1237–1254) — `tenant_a` and `tenant_b` are each provisioned
exactly once by this test (two separate `provisioned_tenant()` calls, lines 173–174, each minting a
fresh `Ecto.UUID`-backed tenant, no id collision possible), so exactly 2 filtered rows is guaranteed
regardless of how many *other*, unrelated ids `:all` also resolved. Not left open — recorded here
for CODE-DESIGN-VALIDATOR's benefit since it's the one new assertion this design adds beyond what
ISSUE-FIXER's recommendation named.

---

## 6. Files touched

| File | Change | Owner |
|---|---|---|
| `test/letflow/tenant_provisioning/column_promotion_test.exs` | AC1 test (lines 171–201): replace exact-set-equality assertion with containment (`tenant_a in ...`, `tenant_b in ...`, §1.1); scope the DDL-execution loop to a `tenant_a`/`tenant_b`-filtered subset of `rows` with a `length(...) == 2` sanity check, instead of iterating the full unscoped `rows` (§1.2). | ELIXIR-DEV |

No other file.

---

## 7. Acceptance-criteria traceability

| Item from ISSUE-FIXER's recommendation / task | Design element |
|---|---|
| Stop asserting exact-list-equality of `:all`'s resolved tenant ids; assert containment instead | §1.1 |
| Decide (not leave open) whether the downstream loop should be scoped to `tenant_a`/`tenant_b`'s own rows | §1.2 (decision: yes, filter; rationale given) |
| No `lib/letflow/` production-code change — `list_registrations/0`'s `:all` semantics are correct | §2, §0.1 point 3, INV-4 |
| Cite ISS-0580 as related prior art | §0 sources-read list, §0.1's closing paragraph, §2's `provision!/2` bullet |
| Confirm ISSUE-FIXER's characterization against actual code before designing | §0.1 (root cause re-derived line-by-line against actual `tenant_provisioning.ex`/test-file content) |
| No implementation code in the design | §§1-2 give only prose descriptions of the assertion/filter logic and cited line ranges — no fenced block in this document contains a runnable `def`/`case`/`if` function body (the two fenced blocks in §1.1 are direct quotes of the *existing* code being replaced, shown for reference, not new code) |
