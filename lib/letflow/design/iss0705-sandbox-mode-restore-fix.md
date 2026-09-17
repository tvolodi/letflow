# Design: ISS-0705 — sandbox `:auto`-mode restore gaps in `tenants_test.exs`/`identity_test.exs` (+ paired `role_registry_test.exs` fix, + orphaned-row cleanup)

**Run:** WF03-ISS0705-20260917 · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR.

**Scope: TEST-FILE CODE ONLY + one operational maintenance command.** Every code change in this
design lands in three existing test files (`test/letflow/routers/tenants_test.exs`,
`test/letflow/routers/identity_test.exs`, `test/letflow/role_registry_test.exs`). No new
`test/support/` helper is added — this design reuses `Letflow.Test.SandboxAutoMode`
(`test/support/sandbox_auto_mode.ex`) exactly as it exists today. No `lib/letflow/` file, no
`priv/repo/migrations/*`, no `config/*.exs` is touched. §5 additionally specifies a one-off
maintenance command (not application code) to delete the 129 already-orphaned `tenants` rows.

---

## 0. Sources read

- `handoffs/WF03-ISS0705-20260917/step-01-issue-fixer-diagnosis.json`'s `result.summary` in full —
  ISSUE-FIXER's diagnosis, not re-derived here except where §0.1 below documents a correction.
- `test/support/sandbox_auto_mode.ex` in full (all three exported functions and their moduledocs).
- `test/letflow/routers/tenants_test.exs` lines 375-444 (the `AC4/AC7: POST /tenants as
  PLATFORM_ADMIN` describe block, including the affected test and its neighbors).
- `test/letflow/routers/identity_test.exs` lines 1355-1386 (the `REQ-076 AC6: role registry routes`
  describe block's `setup`, plus its own leading comment).
- `test/letflow/role_registry_test.exs` lines 90-163 (its `setup` block and the `unique_slug/1` /
  `unique_name/1` helpers immediately above it).
- `lib/letflow/design/iss0580-sandbox-auto-mode-restore-leak.md` in full — the design that created
  `Letflow.Test.SandboxAutoMode`. This design's §3.3 is the load-bearing precedent for §0.1's
  correction below: it documents `enter_auto_mode!/1` / `exit_auto_mode!/1` as a *paired*,
  direction-specific set (enter → `:auto`, exit → `:manual`), not two interchangeable names for "the
  helper used in an `on_exit/1` callback."

### 0.1 Correction to the task handoff's helper choice for identity_test.exs / role_registry_test.exs

The task handoff (and ISSUE-FIXER's diagnosis it quotes) directs: swap the inline
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` at `identity_test.exs:1381`'s `on_exit/1` for
`SandboxAutoMode.exit_auto_mode!/1`. **This is the wrong function for that call site — read literally,
it would break the test.** Verified directly against `test/support/sandbox_auto_mode.ex`:

```
def enter_auto_mode!(repo), do: Sandbox.mode(repo, :auto)   # sets :auto
def exit_auto_mode!(repo),  do: Sandbox.mode(repo, :manual) # sets :manual
```

`exit_auto_mode!/1`'s own moduledoc, and ISS-0580's design §3.3 (its only existing call site,
`engine_concurrency_test.exs`), both describe it as the function that puts the pool back in
`:manual` — the ordinary sandboxed default — once real cross-connection `Task.async` work is
finished. That is the opposite of what `identity_test.exs:1381` and `role_registry_test.exs:119`
need: both sites' `on_exit/1` callback exists specifically to force the pool back to **`:auto`**
(not `:manual`) before `TenantFixture.provisioned_tenant!/1`'s own earlier-registered `on_exit/1`
(the `DROP SCHEMA`/`delete_all` cleanup) runs — because that cleanup needs a real, checked-in
connection, which only `:auto` mode provides from the separate `OnExitHandler` process ExUnit runs
`on_exit/1` callbacks in. Ending at `:manual` here would leave the *later*-running (LIFO) cleanup
`on_exit/1` without a usable connection, reproducing exactly the class of hazard this issue exists
to close, in a new place.

The existing helper that actually does "set `:auto` mode, callable from any process, no checkout" is
`enter_auto_mode!/1` — its body is `Sandbox.mode(repo, :auto)`, with no process-affinity requirement
(unlike `provision!/2`'s restore step, it never calls `Sandbox.checkout/1`, so there is nothing in it
that only works from the original test process). **This design uses `enter_auto_mode!/1`, not
`exit_auto_mode!/1`, at both sites** — still an existing helper, still no new function added,
satisfying the "no new helper invented" instruction while fixing the direction mismatch. Flagged
per this task's "no silently resolving an open question by guessing" instruction rather than
silently substituting it without explanation.

CODE-DESIGN-VALIDATOR: this is the one point in this design that deviates from the task handoff's
literal wording — everything else below follows it as given.

---

## 1. `test/letflow/routers/tenants_test.exs` — wrap with `provision!/2`

### 1.1 Current shape (lines 386-432, the `"creates a tenant row, provisions a real schema, and
replays real migrations"` test)

The test body, in order: a comment block (387-390) → `Sandbox.mode(Letflow.Repo, :auto)` (391) →
`slug` generation (393) → the `dispatch()` POST call and its assertions (395-405) →
`on_exit/1` registration for schema/row cleanup (407-418) → a real `information_schema` query and
final `assert rows != []` (420-431). No restore of `:manual` mode anywhere in the test body or its
`on_exit/1`.

### 1.2 Change

Wrap the segment from immediately after the existing comment block through the test's final
assertion — i.e. everything from `slug = "req075-create-e2e-#{Ecto.UUID.generate()}"` (393) through
`assert rows != []` (431) — in the zero-arity function passed to
`Letflow.Test.SandboxAutoMode.provision!/2`, replacing the standalone
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` line (391) with the `provision!/2` call itself.

Before (shape):
```
test "creates a tenant row, provisions a real schema, and replays real migrations" do
  # <existing comment, unchanged>
  Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

  slug = "req075-create-e2e-#{Ecto.UUID.generate()}"
  <dispatch + assertions>
  <tenant_id extraction>
  on_exit(fn -> <schema drop + row cleanup> end)
  <information_schema query + assert>
end
```

After (shape):
```
test "creates a tenant row, provisions a real schema, and replays real migrations" do
  # <existing comment, unchanged>
  SandboxAutoMode.provision!(Letflow.Repo, fn ->
    slug = "req075-create-e2e-#{Ecto.UUID.generate()}"
    <dispatch + assertions>
    <tenant_id extraction>
    on_exit(fn -> <schema drop + row cleanup> end)
    <information_schema query + assert>
  end)
end
```

Nothing inside the wrapped body changes — same `dispatch()` call, same assertions, same `on_exit/1`
registration (still registered from inside the wrapped function, which still runs in the original
test process, so `on_exit/1`'s own process-registration semantics are unaffected by being nested one
level deeper in a `fn -> ... end`), same `information_schema` query, same final `assert`. Only the
`Sandbox.mode(Letflow.Repo, :auto)` line is removed (subsumed into `provision!/2`'s own first step),
and the file gains one `alias Letflow.Test.SandboxAutoMode` near its existing alias list (or a
fully-qualified `Letflow.Test.SandboxAutoMode.provision!/2` call — ELIXIR-DEV's choice, matching
ISS-0580 design §3.1's own latitude on this point).

`provision!/2`'s own `after`-block restore (`Sandbox.mode(repo, :manual)` +
`Sandbox.checkout(repo)`) now runs unconditionally once the wrapped function returns or raises —
closing the leak whether the test's own assertions pass or fail partway through, matching ISS-0580's
`INV-2`.

### 1.3 Why `provision!/2`, not `enter_auto_mode!/1`/`exit_auto_mode!/1` or `Sandbox.allow/3`

Confirmed by reading the test file's moduledoc (line 13) and the test body itself: the whole test
runs in one process — `dispatch()` calls `Letflow.Routers.Tenants.call/2` directly, no `Task.async`,
no spawned process needing to share this process's checked-out connection. `Sandbox.allow/3` exists
to let a *separate* process share the calling process's connection; there is no separate process
here, so it does not apply (matches ISSUE-FIXER's own reasoning in the diagnosis). Nothing needs
`:auto` mode to remain in effect past the end of this test body (unlike
`engine_concurrency_test.exs`'s `Task.async` case) — `provision!/2`'s immediate-restore shape is the
correct fit, exactly as ISS-0580 §1.2 designed it for.

---

## 2. `test/letflow/routers/identity_test.exs` — swap in `enter_auto_mode!/1`

### 2.1 Current shape (lines 1371-1386, the `REQ-076 AC6: role registry routes` describe block's
`setup`)

```
setup do
  tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-roles")

  Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)

  on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto) end)

  Repo.query!(~s(SET search_path TO "#{tenant.schema_name}", public))

  %{tenant: tenant}
end
```

### 2.2 Change

Replace only the `on_exit/1` callback's body — the single line
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` at line 1381 — with
`Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)` (see §0.1 for why `enter_auto_mode!/1`,
not `exit_auto_mode!/1`). Nothing else in the block changes: `provisioned_tenant!/1`'s own call,
the `:manual` mode flip + checkout, the `on_exit/1` registration's position (still registered
immediately after the checkout, still before `SET search_path`, so it still runs before
`provisioned_tenant!/1`'s own earlier-registered cleanup `on_exit/1` per LIFO — unchanged ordering),
and the `SET search_path` call are all byte-for-byte the same.

Before → after, isolated to the one line:
```
on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto) end)
```
becomes
```
on_exit(fn -> Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo) end)
```

(Or via an `alias Letflow.Test.SandboxAutoMode` added near the file's existing alias list, with the
call written as `SandboxAutoMode.enter_auto_mode!(Letflow.Repo)` — ELIXIR-DEV's choice, matching
§1.2's latitude.)

This is a pure refactor, not a behavior change: `enter_auto_mode!/1`'s body is exactly
`Sandbox.mode(repo, :auto)`, identical to what the inline call already did. The fix is entirely
about routing this call site through the named, documented helper (so a future reader sees *why*
`:auto` mode is being forced here, matching `enter_auto_mode!/1`'s own stated purpose — "named so the
read site says why it is entering `:auto` mode") rather than an unexplained bare `Sandbox.mode` call
— not about changing what mode the pool ends up in.

---

## 3. `test/letflow/role_registry_test.exs` — paired, identical fix

### 3.1 Current shape (lines 101-128, the file's own top-level `setup`)

```
setup do
  Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

  tenant = %Tenant{} |> Tenant.create_changeset(...) |> Repo.insert!()

  on_exit(fn ->
    # <comment, unchanged>
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    case TenantProvisioning.schema_name_for_tenant(tenant.id) do
      ...
    end

    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
  end)

  <provisioning + REQ-063 restore-to-:manual block, lines 130-158, unchanged>

  Repo.query!(~s(SET search_path TO "#{schema_name}", public))

  %{tenant: tenant, schema_name: schema_name}
end
```

### 3.2 Change

Same single-line swap as §2.2, applied at line 119 (the `on_exit/1` callback's own forced-`:auto`
line, inside the comment block that already says "mirrors identity_test.exs's own on_exit/1
handling of this exact hazard"):

```
Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
```
becomes
```
Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
```

The setup block's *own* first line (102) — `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)`,
run once at the very start of `setup`, before `tenant` is even inserted — is **not** touched by this
design. It is a different call site (an initial mode-entry at setup start, not a
restore-before-cleanup call in `on_exit/1`) and ISS-0705's task scope, per the handoff, is the paired
`on_exit/1`-restore fix mirroring `identity_test.exs:1381` specifically — widening this fix to line
102 as well would be exactly the kind of unscoped, silent expansion `docs/anti-patterns.md`/REVIEWER
would flag. Left as an explicit open question (§6, OQ-2) rather than silently folded in or silently
left unmentioned.

Everything else in the block (the `case`/`Repo.delete_all` cleanup body, the REQ-063 restore block at
130-158, the final `SET search_path` and returned map) is unchanged.

---

## 4. Invariants

- **INV-1 — `tenants_test.exs`'s `:auto`-mode window is closed on both the success and failure path
  after this change**, and never widened relative to today (§1.2, mirroring ISS-0580's `INV-1`/`INV-2`).
- **INV-2 — `identity_test.exs`'s and `role_registry_test.exs`'s end-of-test mode (`:auto`) is
  unchanged by this design.** §0.1/§2.2/§3.2 are a pure named-helper substitution, not a behavior
  change — both sites still leave the pool in `:auto` mode when their `on_exit/1` callback returns,
  which is required for `TenantFixture.provisioned_tenant!/1`'s own later-running (LIFO) cleanup
  `on_exit/1` to get a real connection.
- **INV-3 — no test's return value/contract changes.** `tenants_test.exs`'s test still runs the same
  assertions in the same order; `identity_test.exs`'s and `role_registry_test.exs`'s `setup` blocks
  still return `%{tenant: tenant}` / `%{tenant: tenant, schema_name: schema_name}` unchanged.
- **INV-4 — no new `test/support/` module or function is added.** All three fixes call only
  `Letflow.Test.SandboxAutoMode.provision!/2` and `.enter_auto_mode!/1`, both already present in
  `test/support/sandbox_auto_mode.ex` today.
- **INV-5 — the orphaned-row cleanup (§5) is independent of, and not a prerequisite or consequence
  of, either code fix above** (per ISSUE-FIXER's diagnosis: none of the 129 rows are attributable to
  `tenants_test.exs` or `identity_test.exs`'s own fixtures).

---

## 5. Orphaned-row cleanup — one-off maintenance command, not application code

### 5.1 What to delete

Per ISSUE-FIXER's diagnosis (step 1(b)): a fresh `SELECT count(*) FROM tenants` against the shared
test database returned exactly **129** rows, none carrying the `req075-*`/`req076-*` prefixes used by
the two files this issue names — all 129 are leftover rows from unrelated test files' ordinary
`TenantFixture.provisioned_tenant!/1` usage that never got cleaned up (most plausibly: an earlier
interrupted/killed `mix test` run, which skips `on_exit/1` entirely). Per the diagnosis's own framing:
"a clean test DB should hold zero tenant rows between `mix test` invocations" — there is no
currently-running test fixture whose rows should be preserved when this command is run, because it
is a maintenance step run **between** `mix test` invocations, not during one. The command below
therefore does not need a slug-prefix allowlist to protect in-flight fixtures — it needs only the
precondition in §5.3.

### 5.2 Exact command

Run once, from the repo root, against the test database, with no `mix test` running concurrently:

```
MIX_ENV=test mix run -e '
  import Ecto.Query
  alias Letflow.Repo
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning.Registration

  regs = Repo.all(Registration)
  IO.puts("Dropping #{length(regs)} provisioned schema(s)...")

  Enum.each(regs, fn reg ->
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{reg.schema_name}" CASCADE))
  end)

  {reg_count, _} = Repo.delete_all(Registration)
  {tenant_count, _} = Repo.delete_all(Tenant)
  IO.puts("Deleted #{reg_count} tenant_schemas row(s), #{tenant_count} tenants row(s).")
'
```

This is a maintenance script for ELIXIR-DEV to run during WF-03 Step 3, not application code added
to `lib/letflow/` or `test/support/` — it is not committed as a file; it is executed once and its
output (row counts) is recorded in that step's handoff `result.summary`, then discarded.

### 5.3 Precondition (must be checked before running)

No `mix test` process may be running against the same test database when this command runs — it
unconditionally deletes every row in `tenants`/`tenant_schemas`, which would corrupt an in-flight
test's own fixtures if one were running concurrently. ELIXIR-DEV should confirm no other `mix test`
invocation is active (e.g. via `docker compose ps`/process listing appropriate to the local
environment) immediately before running §5.2, per this project's "Concurrent / sibling sessions"
discretion — a single-host, single-session run has no concurrent invocation by construction.

### 5.4 Verification

After running §5.2, `MIX_ENV=test mix run -e 'IO.puts(Letflow.Repo.aggregate(Letflow.Identity.Tenant, :count))'`
should print `0`. Record both the pre-cleanup count (129, already measured by ISSUE-FIXER) and this
post-cleanup count (expected `0`) in the Step 3 handoff.

---

## 6. Open questions

**OQ-1 — the helper-choice correction in §0.1 is this design's own judgment call, not something
CODE-DESIGN-VALIDATOR should treat as pre-approved by ISSUE-FIXER's diagnosis.** The diagnosis names
`exit_auto_mode!/1` explicitly; this design overrides that with `enter_auto_mode!/1` based on
`test/support/sandbox_auto_mode.ex`'s own read implementation and ISS-0580 §3.3's precedent.
CODE-DESIGN-VALIDATOR should re-verify §0.1's reasoning independently before approving, since it is
the one place this design disagrees with its own upstream instruction rather than merely
transcribing it.

**OQ-2 — `role_registry_test.exs:102`'s own setup-start `Sandbox.mode(Letflow.Repo, :auto)` call
(distinct from the `on_exit/1` line this design does fix at line 119) is left unchanged (§3.2).** It
is a different call shape (an unconditional mode-entry with no matching helper call today, since
`enter_auto_mode!/1`'s documented pairing is with a *deferred* `on_exit/1`-registered restore, not an
immediate one) and is outside this issue's named scope. A future consistency pass could route it
through `enter_auto_mode!/1` too, purely for read-site clarity (no behavior change, since it's the
same `Sandbox.mode(repo, :auto)` call either way) — not proposed here to avoid unscoped expansion.

---

## 7. Files touched

| File | Change | Owner |
|---|---|---|
| `test/letflow/routers/tenants_test.exs` | Wrap the real-provisioning test body (lines 393-431) in `SandboxAutoMode.provision!/2`, removing the standalone `Sandbox.mode(..., :auto)` at line 391 (§1). | ELIXIR-DEV |
| `test/letflow/routers/identity_test.exs` | `on_exit/1` at line 1381: swap inline `Sandbox.mode(Letflow.Repo, :auto)` for `SandboxAutoMode.enter_auto_mode!(Letflow.Repo)` (§2). | ELIXIR-DEV |
| `test/letflow/role_registry_test.exs` | `on_exit/1` at line 119: identical swap, paired fix (§3). | ELIXIR-DEV |
| *(no file — operational only)* | Run §5.2's one-off `mix run -e` cleanup against the test DB once during Step 3; record before/after counts. | ELIXIR-DEV |

No `test/support/sandbox_auto_mode.ex` change — this design reuses it exactly as it exists today. No
`lib/letflow/` file, no migration, no `config/*.exs` file is touched.

---

## 8. Acceptance-criteria traceability

| Acceptance criterion | Design element |
|---|---|
| Design doc exists under `lib/letflow/design/` covering all 3 test files and the orphaned-row cleanup | This file, §§1-3, §5 |
| Each fix cites the exact existing helper + call shape; no new helper invented unless stated why | §1 (`provision!/2`), §2/§3 (`enter_auto_mode!/1`, with §0.1's explicit reasoning for departing from the task handoff's named `exit_auto_mode!/1`) |
| No implementation code in the design, only precise specification | §§1-3 give before/after prose + call-shape fences (no fenced block is a compiling standalone module); §5's fence is an operational one-off command, not a file added to the codebase |
| Orphaned-row cleanup specified precisely enough to run mechanically | §5.2 (exact `mix run -e` command), §5.3 (precondition), §5.4 (verification) |
| `next_action` routes to CODE-DESIGN-VALIDATOR | This handoff's `result.next_action` |
