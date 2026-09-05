defmodule Letflow.ISS0480ProvisioningRepoIsolationTest do
  @moduledoc """
  Deterministic fail-then-pass regression test for ISS-0480, built exactly per
  `lib/letflow/design/iss0113-tenant-fixture-sandbox-restore-opt-in.md` §10.6
  (do not re-derive the mechanism from scratch — it is fully specified there).

  ## What ISS-0480 was

  `Letflow.TenantFixture.provisioned_tenant!/1`'s own `Sandbox.mode/2` call
  used to target `Letflow.Repo` directly. `Ecto.Adapters.SQL.Sandbox.mode/2`'s
  check-in-everyone effect is GLOBAL across the whole targeted pool
  (`DBConnection.Ownership.Manager.handle_call({:mode, mode}, ...)`,
  `proxy_checkin_all_except(state, [], caller)` — empty exclusion list, not
  scoped to the calling process). So any concurrently-running `async: true`
  `TenantFixture` caller could silently discard an unrelated, concurrently
  running plain-`DataCase` test's in-flight sandboxed transaction, even
  though that victim test never touched `TenantFixture` at all. Real,
  observed victims: `test/letflow/row_approval_test.exs` and
  `test/letflow/definitions/pack_update_migration_test.exs` (both plain
  `use Letflow.DataCase, async: true`, zero `TenantFixture` involvement in
  their own test bodies) — see
  `handoffs/WF03-ISS0480-20260905/step-0.5-1-issue-fixer-diagnose.json` for
  the original live-suite capture this test reproduces deterministically
  instead of relying on suite-wide scheduling luck.

  ## Why this test's shape mirrors the real victims exactly

  This module is deliberately, per §10.6's own instruction, the SAME shape
  as `RowApprovalTest`/`PackUpdateMigrationTest`: plain
  `use Letflow.DataCase, async: true`, zero `TenantFixture` involvement in
  ITS OWN test body. The only `TenantFixture` call in this file happens
  inside a `Task.async/1`-spawned SEPARATE process, deliberately manufacturing
  the exact "some other concurrently-running `TenantFixture` caller" scenario
  ISS-0480 needs — the same "simulate the race directly, don't wait for
  ExUnit's own scheduler to land it by luck" discipline ISS-0110's own design
  used (§10.6's own closing paragraph names this parallel explicitly).

  ## Pre-fix / post-fix behavior

  - **Pre-fix** (`provisioned_tenant!/1`'s `Sandbox.mode(Letflow.Repo,
    :auto)` line targeting `Letflow.Repo` directly): the spawned Task's call
    checks in the OUTER test process's own `Letflow.Repo` connection,
    discarding its in-flight transaction. The outer test's later
    `RowApproval.get/1` then either observes the row as absent (transaction
    rolled back on check-in) or the outer process raises
    `DBConnection.OwnershipError` — either way, this test fails
    deterministically, every run.
  - **Post-fix** (`provisioned_tenant!/1` targets
    `Letflow.Test.ProvisioningRepo`, a structurally separate
    `DBConnection.Ownership.Manager`): the spawned Task's call cannot reach
    anything checked out from `Letflow.Repo`'s own pool. The outer test's row
    stays visible unconditionally. This test passes.
  """

  use Letflow.DataCase, async: true

  alias Letflow.RowApproval

  test "a concurrent TenantFixture.provisioned_tenant!/1 caller does not discard this test's own in-flight Letflow.Repo transaction" do
    # Step 1: establish an in-flight, uncommitted insert on THIS test
    # process's own checked-out Letflow.Repo connection -- exactly
    # RowApprovalTest's own shape between its create() and later get() calls.
    {:ok, id} = RowApproval.create()
    assert %{status: :pending} = RowApproval.get(id)

    # Step 2: deliberately manufacture the adversarial concurrent caller --
    # a SEPARATE process that calls Letflow.TenantFixture.provisioned_tenant!/1
    # directly, default opts, mirroring ISS-0480's own real-world trigger
    # (some other async: true TenantFixture caller running concurrently)
    # without depending on ExUnit's own scheduler happening to interleave
    # two unrelated test modules at the right instant.
    # teardown: false -- provisioned_tenant!/1 would otherwise call
    # ExUnit's on_exit/1 from inside this spawned Task, which ExUnit
    # rejects ("on_exit/2 callback can only be invoked from the test
    # process"). That is a Task/ExUnit-callback constraint orthogonal to
    # ISS-0480's own mechanism (which concerns Sandbox.mode/2's targeted
    # pool, not which process may register a callback) -- opting out of
    # this fixture's own teardown here leaves a harmless, already-real
    # (never-sandboxed, per design §9.3/§10.3.4) provisioned tenant/schema
    # behind, exactly as any other `teardown: false` caller already does
    # per this fixture's own documented, pre-existing opt-out.
    task =
      Task.async(fn ->
        Letflow.TenantFixture.provisioned_tenant!(teardown: false)
      end)

    # Step 3: await the spawned process, so this test's own subsequent
    # assertion runs strictly after provisioned_tenant!/1's own
    # Sandbox.mode/2 call (whichever repo it targets, pre- or post-fix) has
    # already executed and returned.
    fixture = Task.await(task, 30_000)
    assert %{tenant_id: _, schema_name: _, tenant: _} = fixture

    # Step 4: assert the row inserted in step 1 is STILL visible via a fresh
    # read on the SAME test process -- the exact property ISS-0480's two real
    # victims lost (RowApprovalTest's {:error, :not_found}, PackUpdateMigrationTest's
    # FK violation against a vanished parent row).
    assert %{status: :pending} = RowApproval.get(id)
  end
end
