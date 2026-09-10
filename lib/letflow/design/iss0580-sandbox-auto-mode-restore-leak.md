# Design: ISS-0580 — restore sandbox isolation after `:auto`-mode tenant provisioning fixtures

**Run:** fix/ISS-0580-20260910 (GH#1189, queue task 580) · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR.

**Scope: TEST-SUPPORT / TEST-FILE CODE ONLY.** Every change in this design lands in a new
`test/support/sandbox_auto_mode.ex` helper plus edits to 7 existing test files under `test/letflow/`.
No `lib/letflow/` file, no `priv/repo/migrations/*`, no `config/*.exs` is touched. See §6 for the
explicit scope confirmation and SECURITY-REVIEWER scoping statement.

---

## 0. Sources read

- `docs/agents/instructions/core-directives.md`, `docs/agents/workflows/WF-02_requirement_implementation.md`
  Step 1, `docs/anti-patterns.md`, `docs/guides/backend_developer_guide.md` (test-support conventions).
- `test/letflow/role_registry_test.exs` in full — the established safe restore pattern (its `setup`
  block, lines 101-163).
- `test/letflow/tenant_provisioning/column_promotion_test.exs`, `test/letflow/entities/records_test.exs`,
  `test/letflow/audit_dispositions_test.exs`, `test/letflow/audit_capture_test.exs`,
  `test/letflow/audit_test.exs`, `test/letflow/repository_test.exs`, `test/letflow/engine_concurrency_test.exs`
  — each file's `provisioned_tenant/0` (or `setup`) helper, read in full for its own file's own
  `:auto`-mode usage and everything downstream of it in the same test/setup body.
- `test/support/data_case.ex` — the baseline `Letflow.DataCase` sandbox setup (`Sandbox.checkout/1`
  + `{:shared, self()}` for `async: false` modules) this pattern works around.
- `scripts/test_parallel.sh` (lines 185-190) — confirms `engine_concurrency_test.exs`'s
  `@moduletag :high_pool_demand` is excluded (`--exclude high_pool_demand`) whenever
  `TEST_POOL_SIZE < 100`, which is unconditionally true for any `N >= 2` partition run — i.e. this
  file never runs concurrently with the async suite under the actual parallel-partitioned CI/local
  run this issue's flake was reproduced under. Relevant to §3.3's scoping of that file's fix.
- `lib/letflow/design/iss0578-tenant-clone-transient-connection-retry.md` — reused for this design's
  own section shape and `@spec`-only / no-function-body style (this design follows the same
  documentation convention, not the same subject matter).
- `test/support/tenant_template.ex` (`defmodule Letflow.Test.TenantTemplate`) and
  `test/support/tenant_slug.ex` (`defmodule Letflow.TenantSlugFixture`) — confirms this codebase's
  test-support module-naming convention is not fully uniform (`Letflow.Test.*` alongside bare
  `Letflow.*Fixture`); this design follows the `Letflow.Test.*` form as the closer precedent for a
  sandbox/connection-mode helper (same category of concern as `Letflow.Test.TenantTemplate`, not a
  tenant/fixture-data helper like `TenantSlugFixture`).

### 0.1 Root cause, restated (ISSUE-FIXER's diagnosis, not re-litigated)

Six test files' local `provisioned_tenant/0` helpers (a seventh, `engine_concurrency_test.exs`, is a
distinct case — see §3.3) call `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` to let real
`TenantProvisioning`/`Ecto.Migrator` DDL work commit for real (the sandbox's single shared connection
cannot run `Ecto.Migrator`, per `lib/letflow/design/req022-tenant-schema-provisioning.md` §6), and
never restore `:manual` mode + a fresh `Sandbox.checkout/1` afterward. `Sandbox.mode/2` is a
pool-wide global, not scoped to the calling process — leaving it in `:auto` for the rest of the test
body (which, for these six files, is the entire remaining test — every assertion after
`provisioned_tenant()` returns) makes every *other* `async: true` test's `Repo` writes, running
concurrently in the same suite, become real uncommitted-forever commits instead of
rollback-isolated ones. That leaked state later collides with an unrelated test's own
unique-constraint expectations (the reproducible `ColumnPromotionTest` AC1 flake this issue starts
from).

### 0.2 Citation correction (ISSUE-FIXER's diagnosis, verified against current file content)

The task handoff's citation "add the same restore-to-manual-mode pattern from `role_registry_test.exs`
lines 128-140" is **off by ~29 lines**. Lines 128-140 of the current file are the tail of the
`on_exit/1` cleanup callback (`Repo.delete_all(...)` calls and the closing `end)`), not the restore
call. The actual restore-to-`:manual`-mode-plus-fresh-checkout pattern this design generalizes is at
**lines 157-158**: a call flipping `Ecto.Adapters.SQL.Sandbox.mode/2` back to `:manual` for
`Letflow.Repo`, immediately followed by a fresh `Ecto.Adapters.SQL.Sandbox.checkout/1` on that same
repo (asserted to return `:ok`), and then followed by the `SET search_path` call the restored
connection needs (line 160), all
still inside the `setup` block, before the test body itself runs. §1 below generalizes exactly this
three-line sequence (mode flip + checkout, done in the calling test process, before returning to the
caller). All six affected files' own line citations were re-verified directly and matched
ISSUE-FIXER's diagnosis (see §3.1's table) — the role-registry citation is the only correction
needed.

### 0.3 A second, narrower leak ISSUE-FIXER's diagnosis did not call out

Each of the six `provisioned_tenant/0` helpers also has an un-restored `:auto` window on its own
**failure path**: if `insert_tenant!()` or any `assert {:ok, ...} = TenantProvisioning...` call
inside the helper itself raises (an `ExUnit.AssertionError` from a failed `assert`, or any other
exception), the helper never reaches its own end, so today there is no restore call to reach anyway
— global mode is left at `:auto` indefinitely, whether or not this design exists. §1.2 below closes
this too (via `after`, not just a fall-through at the end of the function), as a strict safety
improvement over the literal pattern in `role_registry_test.exs`'s `setup` block (which has the same
gap — a raise before line 157 there leaves mode at `:auto` unrestored as well, unnoticed until now
because that file's own provisioning calls have not been observed to fail). Flagged explicitly per
this task's "no silently resolving an open question by guessing" instruction — see OQ-2 (§7) for
why this is *not* proposed as a change to `role_registry_test.exs` itself.

---

## 1. New shared helper — `test/support/sandbox_auto_mode.ex`

### 1.1 Module

`Letflow.Test.SandboxAutoMode` — new file, `test/support/sandbox_auto_mode.ex`. Compiled only under
`elixirc_paths(:test)` (same visibility as every other file in `test/support/`), never reachable from
`lib/letflow/`.

### 1.2 `provision!/2` — the self-restoring variant (six call sites, §3.1-§3.2)

```
@spec provision!(repo :: module(), fun :: (-> result)) :: result when result: term()
```

Behavior, in prose:

1. Set `Sandbox.mode(repo, :auto)`.
2. Invoke `fun.()` inside a `try`.
3. In an `after` block (runs whether `fun.()` returns normally or raises) — restore
   `Sandbox.mode(repo, :manual)`, then `Sandbox.checkout(repo)` for the calling process. This closes
   §0.3's failure-path gap: the global mode is put back to `:manual` even if the caller's own
   provisioning `assert`s fail partway through, not only on the success path `role_registry_test.exs`
   itself covers today.
4. Return `fun.()`'s result unchanged (or let the original exception propagate after the `after`
   block's restore has run — Elixir's `try/after` semantics already do this: `after` always runs,
   then the original raise/return continues).

Callers pass a zero-arity function containing exactly the provisioning work that today runs between
the file's own `Sandbox.mode(Letflow.Repo, :auto)` line and the end of its `provisioned_tenant/0`
function (tenant insert, `on_exit/1` registration, `provision_tenant_schema/1`,
`replay_migrations/2`, and any file-specific seed/`SET search_path` step) — see §3.1/§3.2 for each
site's exact split.

Named `provision!` (not `run_and_restore!` or similar) to read naturally at each call site as "do the
provisioning work, then restore" — matching this codebase's existing `!`-suffix convention for
functions that raise/assert on failure rather than returning an `{:error, _}` tuple (all six
`provisioned_tenant/0` helpers already raise via `assert` on any provisioning failure; `provision!/2`
does not change that — a raised `ExUnit.AssertionError` from inside `fun` still propagates, per step 4
above).

### 1.3 `enter_auto_mode!/1` and `exit_auto_mode!/1` — the held-open variant (`engine_concurrency_test.exs`, §3.3)

```
@spec enter_auto_mode!(repo :: module()) :: :ok
@spec exit_auto_mode!(repo :: module()) :: :ok
```

`enter_auto_mode!/1` is a thin, documented wrapper around `Sandbox.mode(repo, :auto)` — behaviorally
identical to today's inline call, added only so the call site names *why* it is entering `:auto` mode
and pairs visibly with `exit_auto_mode!/1` at the read-site.

`exit_auto_mode!/1` sets `Sandbox.mode(repo, :manual)` **only** — it does **not** call
`Sandbox.checkout/1`. This is the deliberate difference from `provision!/2`: `exit_auto_mode!/1` is
designed to be called from an `on_exit/1` callback, which ExUnit runs in a separate
`spawn_monitor`-ed process, not the original test process (see `role_registry_test.exs`'s own
moduledoc, "Sandbox mode: what ACTUALLY protects against cross-test leakage" section, for why a
`Sandbox.checkout/1` issued from the wrong process would silently target that process instead and
not help the original test process's own connection state). No checkout is needed here because, by
the time this call fires, the test process itself is exiting — nothing in that process will run
another `Repo` call afterward.

Why two separate exported functions instead of one `provision!/2`-shaped call for this file: unlike
the six-file case, `engine_concurrency_test.exs`'s test bodies must keep issuing **real** (uncommitted
rollback does not apply), separately-connected `Repo` calls — via `Task.async` bodies each getting
their own genuine pooled connection — for the entire remainder of the test, not just during fixture
setup (see §3.3). `provision!/2`'s restore-immediately-after-`fun` shape would defeat that file's own
documented purpose (genuine cross-connection concurrency, its moduledoc's own "Shared mode would...
defeat AC1/AC4's 'genuine cross-instance parallelism' requirement" point) if applied unchanged, so
this file needs the mode held open across the whole test body and closed only once, at the very end.

---

## 2. Behavior preserved at every call site

Every one of the seven call sites' own return value is unchanged by this design:

- The six `provisioned_tenant/0` functions (§3.1/§3.2) still return `%{tenant_id: ..., schema_name:
  ...}` (or, for `role_registry_test.exs`'s `setup` block itself if it were touched — it is not, see
  §3.2 note) exactly as today; only *how* the `:auto`-mode window is closed changes, not what the
  function hands back to its caller.
- `engine_concurrency_test.exs`'s `provisioned_tenant/0` (§3.3) is unchanged in its own body except
  for the `on_exit/1` registration order describe in §3.3 — its return shape (`%{tenant_id: ...,
  schema_name: ...}`) and the fact that `:auto` mode remains in effect for the rest of that test's
  body are both preserved exactly, since that behavior is this file's own load-bearing requirement,
  not a defect.

---

## 3. Call-site changes

### 3.1 The six `provisioned_tenant/0` sites using `provision!/2` — line citations re-verified

| File | `provisioned_tenant/0` span (current) | `Sandbox.mode(..., :auto)` line | ISSUE-FIXER's citation | Correction needed? |
|---|---|---|---|---|
| `test/letflow/tenant_provisioning/column_promotion_test.exs` | 56-79 | 57 | "lines 56-79" | None — matches exactly. |
| `test/letflow/entities/records_test.exs` | 60-82 | 61 | "lines 60-61" | None — matches (bounds the `defp`/mode-call pair). |
| `test/letflow/audit_dispositions_test.exs` | 68-89 | 69 | (file named, no line cited) | N/A — recorded here for the first time. |
| `test/letflow/audit_capture_test.exs` | 54-75 | 55 | (file named, no line cited) | N/A — recorded here for the first time. |
| `test/letflow/audit_test.exs` | 50-71 | 51 | (file named, no line cited) | N/A — recorded here for the first time. |
| `test/letflow/repository_test.exs` | 56-77 | 57 | (file named as "repository_test.exs", path guessed correctly at `test/letflow/repository_test.exs`) | None. |

All six helpers share the identical shape: `Sandbox.mode(Letflow.Repo, :auto)` as the first line,
then `insert_tenant!()`, an `on_exit/1` registration (schema drop + row cleanup), a
`provision_tenant_schema/1` + `replay_migrations/2` pair (plus, for `column_promotion_test.exs` and
`records_test.exs` only, an `EventTypes.seed!/1` call), and a final `%{tenant_id: ..., schema_name:
...}` map literal as the return value.

**Change, identical in shape at all six sites:** wrap the helper's existing body — everything from
the line *after* the `Sandbox.mode(Letflow.Repo, :auto)` call through the final `%{tenant_id: ...,
schema_name: ...}` map literal — in the zero-arity function passed to `SandboxAutoMode.provision!/2`,
and replace the inline `Sandbox.mode(Letflow.Repo, :auto)` line itself with the `provision!/2` call
wrapping that function. Concretely, each `provisioned_tenant` function's body becomes a single
expression: `SandboxAutoMode.provision!(Letflow.Repo, fn -> <existing body minus the auto-mode line>
end)`. Nothing inside the wrapped body changes — the `on_exit/1` registration, the two
`TenantProvisioning` calls, the optional seed call, and the returned map are byte-for-byte the same
code, just relocated inside the anonymous function's body. Each file adds one `alias
Letflow.Test.SandboxAutoMode` (or a fully-qualified call, ELIXIR-DEV's choice) near its existing
alias list.

### 3.2 `role_registry_test.exs` — not changed by this design

`role_registry_test.exs` already implements the safe pattern by hand (§0.2) and is the source this
design generalizes from, not a defect to fix. Left untouched. (Its own §0.3-class failure-path gap —
a raise before its line 157 leaving mode unrestored — is named as OQ-2, §7, not silently fixed here:
changing an already-passing, unrelated file's failure-path behavior as a side effect of this task
would be exactly the kind of scope creep `docs/anti-patterns.md`/REVIEWER would flag.)

### 3.3 `engine_concurrency_test.exs` — `enter_auto_mode!/1` + deferred `exit_auto_mode!/1`

Confirmed by reading the full file: `provisioned_tenant/0` (lines 90-118) is called from three
separate tests (lines 313, 364, 413), and at least two of those tests launch `Task.async` bodies
(lines 231/254 and 370/379) — real, separately-checked-out-connection concurrent work — *after*
`provisioned_tenant()` has already returned. Per this file's own moduledoc (quoted in §0.1), this is
deliberate: `{:shared, self()}` mode would serialize every `Task.async` body onto one connection and
defeat AC1/AC2/AC4's "genuine cross-instance parallelism" requirement. `:auto` mode must therefore
stay in effect for the whole remainder of each of these three tests, not just during
`provisioned_tenant/0` itself — `provision!/2` (§1.2, §3.1) is the wrong tool here because its
`after`-block restore would flip mode back to `:manual` before the `Task.async` bodies run, breaking
real concurrency for exactly the tests this file exists to exercise.

Also confirmed (§0, `scripts/test_parallel.sh` lines 185-190): this file's `@moduletag
:high_pool_demand` (line 53) is excluded from every `N >= 2`-partition run of
`scripts/test_parallel.sh` (the parallel-suite scenario ISSUE-FIXER's diagnosis is about), because
`TEST_POOL_SIZE < 100` is unconditionally true for any such run and the exclusion fires whenever that
holds. This file therefore does not currently reproduce ISS-0580's reported flake under the actual
parallel CI/local run — it can still leak into a plain, non-partitioned `mix test` run that happens
to interleave it with `async: true` modules, a narrower and separately-plausible exposure this design
closes anyway for consistency, at zero cost to this file's own test behavior.

**Change:** in `provisioned_tenant/0` (lines 90-118),

1. Replace the inline `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` (line 91) with
   `SandboxAutoMode.enter_auto_mode!(Letflow.Repo)`.
2. Register a **new, first** `on_exit/1` callback — before the existing `on_exit/1` (which does the
   `DROP SCHEMA`/`delete_all` cleanup, and itself still needs `:auto` mode active when it runs, so it
   is not otherwise touched) — whose body is exactly `SandboxAutoMode.exit_auto_mode!(Letflow.Repo)`.
   Because ExUnit runs `on_exit/1` callbacks in LIFO order (most-recently-registered first), placing
   this registration *before* the existing cleanup `on_exit/1` call means the existing cleanup
   callback (which needs `:auto` mode to actually commit its `DROP SCHEMA`/`delete_all` work) still
   runs **first**, and `exit_auto_mode!/1` runs **last** — after cleanup has finished, closing the
   global `:auto` window for good before the next test anywhere in the suite acquires a connection.
   No change to the existing cleanup `on_exit/1` callback's own body.

Return value of `provisioned_tenant/0` is unchanged (`%{tenant_id: ..., schema_name: ...}`); the
three call sites (lines 313, 364, 413) and the `Task.async` bodies they precede are not touched at
all.

---

## 4. Invariants

- **INV-1 — the six-file fix never widens the `:auto`-mode exposure window beyond what already
  exists today; it only shortens it.** `provision!/2` enters `:auto` mode at exactly the same point
  each file already does and exits it strictly earlier (immediately after the wrapped provisioning
  work finishes, instead of never) — no site's `:auto` window gets longer.
- **INV-2 — `provision!/2` restores on both the success and failure path.** Per §1.2 step 3 (`after`
  block), a raised exception from inside the wrapped provisioning function does not leave global mode
  stuck at `:auto` — closing §0.3's gap for all six sites, without needing a corresponding change in
  `role_registry_test.exs` itself (OQ-2, §7).
- **INV-3 — no site's return value or contract changes.** Every caller of the six `provisioned_tenant/0`
  functions (test bodies within the same file) keeps pattern-matching `%{tenant_id: ..., schema_name:
  ...}` exactly as before (§2).
- **INV-4 — `engine_concurrency_test.exs`'s genuine cross-connection concurrency is preserved exactly.**
  `:auto` mode remains in effect for the entire body of each of its three tests, including every
  `Task.async` call — `enter_auto_mode!/1`/`exit_auto_mode!/1` change only *when and how* the global
  mode gets reset relative to today (never, today), not the window's extent during the test body
  itself (§3.3, INV-1's "only shortens it" does not apply to this file the same way — see OQ-1, §7,
  for the residual, unavoidable-without-redesign exposure this file still carries during its own test
  bodies).
- **INV-5 — `Letflow.Test.SandboxAutoMode` has zero references from `lib/letflow/`.** New file lives
  under `test/support/`, compiled only under `elixirc_paths(:test)` (§1.1), matching every other file
  in that directory.

---

## 5. Why not a single unified helper for all seven sites

Considered and rejected: making `provision!/2` itself accept an option like `restore: :immediate |
:deferred` to cover both shapes in one function. Rejected because `engine_concurrency_test.exs`'s
"deferred" case does not restore inside the same function call at all — it restores from a
*different*, later-registered `on_exit/1` callback, in a different process, with no checkout step
(§1.3). Folding that into one function's option flag would either (a) require `provision!/2` itself to
take an `on_exit/1`-registering responsibility it does not otherwise need, coupling it to ExUnit's
callback-ordering semantics for every caller even the simple six, or (b) require the "deferred" case
to still call the checkout-including restore late, which is wrong for a call from a foreign process
(§1.3). Two small, separately-named functions make each call site's own contract obvious at the read
site instead of hidden behind an option atom — matching this task's own instruction that the split
between files be stated in prose reasoning, not silently unified past the real behavioral difference.

---

## 6. Scope confirmation — test-support / test-file only, not a SECURITY-REVIEWER gate

- Every function this design adds (`Letflow.Test.SandboxAutoMode.provision!/2`, `enter_auto_mode!/1`,
  `exit_auto_mode!/1`) lives in `test/support/sandbox_auto_mode.ex`, compiled only under
  `elixirc_paths(:test)` — never reachable from `lib/letflow/`, never referenced from
  `lib/letflow/application.ex`'s supervision tree, not a GenServer.
- Every edited file (the six `provisioned_tenant/0` sites plus `engine_concurrency_test.exs`) is
  itself a `test/letflow/**/*.exs` file.
- No `lib/letflow/` file is touched. No `priv/repo/migrations/*` file is touched. No `config/*.exs`
  file is touched.
- Per ISSUE-FIXER's own explicit instruction (restated in the task handoff): **no upsert/idempotency
  logic is added to `register_column_promotion/4` or any other `lib/letflow/` function** — the unique
  constraint firing under the original flake is correct production behavior; this design touches only
  the test harness that leaked state into it.
- This is **not** a tenant-data-path change in the `docs/agents/instructions/security-invariants.md`
  sense: no API route, no migration, no response shaping, no production secret/credential is touched.
  The schemas this design's helper flips sandbox mode around
  (`column_promotion_test.exs`'s/etc.'s per-test tenant schemas) are themselves already test-only,
  throwaway artifacts created and destroyed entirely within `test/` and `test/support/`.
- Recommendation to CODE-DESIGN-VALIDATOR: **SECURITY-REVIEWER sign-off can be skipped** for this
  design, unless CODE-DESIGN-VALIDATOR itself disagrees with this scoping.

---

## 7. Open questions

**OQ-1 — `engine_concurrency_test.exs` still carries a residual `:auto`-mode exposure window for the
duration of its own three tests' bodies, by design necessity (§3.3, INV-4).** This is unavoidable
without redesigning that file's concurrency mechanism entirely (it would have to stop using real
`Task.async` connections, defeating the point of the file), and is not newly introduced by this
design — it is the same exposure that exists today, merely now *bounded and closed* afterward instead
of left open forever. Under the actual `scripts/test_parallel.sh` parallel-partition scenario this
file is excluded via `@moduletag :high_pool_demand` (§3.3), so it does not currently contribute to
the reproducible flake ISS-0580 started from; it remains a narrower, separately-plausible exposure
under a plain non-partitioned `mix test` run. Named rather than silently treated as fully closed by
this design.

**OQ-2 — `role_registry_test.exs`'s own `on_exit/1` cleanup callback (§0.2, lines 112-128) forces
`:auto` mode for its `DROP SCHEMA`/`delete_all` cleanup and never restores afterward, and its `setup`
block (§0.3) has the same pre-line-157-raise gap this design closes for the six other files via
`provision!/2`'s `after` block.** Not changed by this design, and not proposed to be: this is an
existing, working, currently-passing file outside ISS-0580's named scope (six specific files plus
`engine_concurrency_test.exs`), and touching it risks exactly the "went off-script" failure mode this
task's own instructions warn against. If a future issue wants `role_registry_test.exs` itself
migrated onto `SandboxAutoMode.provision!/2` for consistency (its `setup` block's shape is a natural
fit — §1.2's wrapped-body split applies to it identically), that is a separate, small follow-up this
design does not take on.

---

## 8. Files touched

| File | Change | Owner |
|---|---|---|
| `test/support/sandbox_auto_mode.ex` | **New file.** `defmodule Letflow.Test.SandboxAutoMode` with `provision!/2`, `enter_auto_mode!/1`, `exit_auto_mode!/1` (§1). | ELIXIR-DEV |
| `test/letflow/tenant_provisioning/column_promotion_test.exs` | `provisioned_tenant/0` (56-79) wrapped in `SandboxAutoMode.provision!/2` (§3.1). | ELIXIR-DEV |
| `test/letflow/entities/records_test.exs` | `provisioned_tenant/0` (60-82) wrapped in `SandboxAutoMode.provision!/2` (§3.1). | ELIXIR-DEV |
| `test/letflow/audit_dispositions_test.exs` | `provisioned_tenant/0` (68-89) wrapped in `SandboxAutoMode.provision!/2` (§3.1). | ELIXIR-DEV |
| `test/letflow/audit_capture_test.exs` | `provisioned_tenant/0` (54-75) wrapped in `SandboxAutoMode.provision!/2` (§3.1). | ELIXIR-DEV |
| `test/letflow/audit_test.exs` | `provisioned_tenant/0` (50-71) wrapped in `SandboxAutoMode.provision!/2` (§3.1). | ELIXIR-DEV |
| `test/letflow/repository_test.exs` | `provisioned_tenant/0` (56-77) wrapped in `SandboxAutoMode.provision!/2` (§3.1). | ELIXIR-DEV |
| `test/letflow/engine_concurrency_test.exs` | `provisioned_tenant/0` (90-118): inline `Sandbox.mode(..., :auto)` (91) replaced by `enter_auto_mode!/1`; new first-registered `on_exit/1` calling `exit_auto_mode!/1` added before the existing cleanup `on_exit/1` (§3.3). | ELIXIR-DEV |

No other file. `test/letflow/role_registry_test.exs` is read-only source material (§3.2) — not
edited.

---

## 9. Acceptance-criteria traceability

| Item from ISSUE-FIXER's recommendation / task | Design element |
|---|---|
| Add the safe restore pattern to all 6 affected files | §3.1 (table + wrap-in-`provision!/2` change, identical shape at all six sites) |
| Extract the safe pattern into a shared `test/support/` helper so future `:auto`-mode fixtures can't omit the restore | §1 (`Letflow.Test.SandboxAutoMode`, new file) |
| Do not add upsert/idempotency logic to `register_column_promotion/4` | §6 (explicit confirmation — no `lib/letflow/` file touched) |
| Confirm/correct ISSUE-FIXER's line citations against actual file content | §0.2 (role-registry citation corrected: 157-158, not 128-140) and §3.1's table (all six files' own citations re-verified, one already-exact, five recorded for the first time) |
| Handle `engine_concurrency_test.exs`'s same defect without breaking its own real-concurrency purpose | §3.3 (`enter_auto_mode!/1` + deferred `exit_auto_mode!/1` via `on_exit/1` ordering, not `provision!/2`) |
| Confirm test-support/test-file-only scope; SECURITY-REVIEWER skip recommendation | §6 |
| No implementation code in the design | §§1-3 give only `@spec` signatures and prose descriptions of control flow, sequencing, and reasoning — no fenced block anywhere in this document contains a `def`/`case`/`if`/`rescue` function body |
