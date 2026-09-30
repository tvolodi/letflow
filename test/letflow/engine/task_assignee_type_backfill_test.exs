defmodule Letflow.Engine.TaskAssigneeTypeBackfillTest do
  @moduledoc """
  Tests for `Letflow.Engine.TaskAssigneeTypeBackfill` (ISS-0905) — see
  `docs/issues/ISS-0905.yaml` and
  `lib/letflow/design/iss0905-role-assignee-type-not-derived.md` §3 for the
  full design this module implements.

  Uses `Letflow.DataCase` (real Postgres) and `Letflow.TenantFixture` for
  real provisioned tenant schemas, matching
  `test/letflow/identity/role_backfill_test.exs`'s established pattern for
  this exact class of backfill module. `async: false`: tenant provisioning
  needs `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TaskAssigneeTypeBackfill
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Engine.TokenRecord
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  # Inserts a bare tasks row directly (bypassing resolve_assignee/1
  # entirely, matching tasks_test.exs's own insert_task!/2 fixture shape) --
  # used here to construct the exact pre-ISS-0905-bug row shape
  # (assignee_type: nil, assignee_ref: non-nil) this backfill targets.
  defp insert_broken_task!(schema_name, attrs \\ %{}) do
    instance_id = Ecto.UUID.generate()

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)

    token =
      %TokenRecord{}
      |> TokenRecord.insert_changeset(%{
        instance_id: instance_id,
        node_id: "review",
        branch_id: "b1"
      })
      |> Repo.insert!(prefix: schema_name)

    default = %{
      instance_id: instance_id,
      token_id: token.id,
      node_id: "review",
      node_name: "Review",
      assignee_type: nil,
      assignee_ref: "role-ops-manager"
    }

    %EngineTask{}
    |> EngineTask.insert_changeset(Map.merge(default, attrs))
    |> Repo.insert!(prefix: schema_name)
  end

  describe "run/0 repairs pre-ISS-0905-broken rows" do
    test "a row with assignee_type: nil, assignee_ref: non-nil is repaired to assignee_type: \"ROLE\"" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0905-backfill")

      broken = insert_broken_task!(schema_name)

      assert {:ok, %{repaired: repaired, unchanged: _unchanged}} = TaskAssigneeTypeBackfill.run()

      assert {tenant_id, 1} in repaired

      repaired_row = Repo.get!(EngineTask, broken.id, prefix: schema_name)
      assert repaired_row.assignee_type == "ROLE"
      assert repaired_row.assignee_ref == "role-ops-manager"
    end

    test "a genuinely unassigned row (assignee_type: nil, assignee_ref: nil) is left untouched" do
      %{schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0905-backfill-unassigned")

      untouched = insert_broken_task!(schema_name, %{assignee_ref: nil})

      assert {:ok, _} = TaskAssigneeTypeBackfill.run()

      row = Repo.get!(EngineTask, untouched.id, prefix: schema_name)
      assert row.assignee_type == nil
      assert row.assignee_ref == nil
    end

    test "an already-correctly-assigned row (USER/GROUP/ROLE) is left untouched" do
      %{schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0905-backfill-correct")

      already_user =
        insert_broken_task!(schema_name, %{
          node_id: "n2",
          assignee_type: "USER",
          assignee_ref: Ecto.UUID.generate()
        })

      assert {:ok, _} = TaskAssigneeTypeBackfill.run()

      row = Repo.get!(EngineTask, already_user.id, prefix: schema_name)
      assert row.assignee_type == "USER"
    end

    test "a non-pending (completed) row with the broken shape is repaired too (no status filter)" do
      %{schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0905-backfill-completed")

      broken = insert_broken_task!(schema_name)

      broken
      |> Ecto.Changeset.change(%{status: :completed})
      |> Repo.update!(prefix: schema_name)

      assert {:ok, %{repaired: repaired}} = TaskAssigneeTypeBackfill.run()
      assert length(repaired) == 1

      row = Repo.get!(EngineTask, broken.id, prefix: schema_name)
      assert row.assignee_type == "ROLE"
      assert row.status == :completed
    end

    test "a tenant with no broken rows is reported :unchanged" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0905-backfill-noop")

      assert {:ok, %{repaired: _repaired, unchanged: unchanged}} = TaskAssigneeTypeBackfill.run()
      assert tenant_id in unchanged
    end
  end

  describe "run/0 is idempotent" do
    test "a second call reports the tenant as :unchanged and does not re-touch already-repaired rows" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0905-backfill-idem")

      broken = insert_broken_task!(schema_name)

      assert {:ok, %{repaired: repaired_first}} = TaskAssigneeTypeBackfill.run()
      assert {tenant_id, 1} in repaired_first

      assert {:ok, %{repaired: repaired_second, unchanged: unchanged_second}} =
               TaskAssigneeTypeBackfill.run()

      refute Enum.any?(repaired_second, fn {t, _count} -> t == tenant_id end)
      assert tenant_id in unchanged_second

      row = Repo.get!(EngineTask, broken.id, prefix: schema_name)
      assert row.assignee_type == "ROLE"
    end
  end

  describe "run/0 processes every tenant independently" do
    test "backfilling tenant A does not affect tenant B's own rows" do
      %{tenant_id: tenant_id_a, schema_name: schema_a} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0905-backfill-multi-a")

      %{tenant_id: tenant_id_b, schema_name: schema_b} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0905-backfill-multi-b")

      broken_a = insert_broken_task!(schema_a)
      untouched_b = insert_broken_task!(schema_b, %{assignee_ref: nil})

      assert {:ok, %{repaired: repaired}} = TaskAssigneeTypeBackfill.run()

      assert {tenant_id_a, 1} in repaired
      refute Enum.any?(repaired, fn {t, _count} -> t == tenant_id_b end)

      assert Repo.get!(EngineTask, broken_a.id, prefix: schema_a).assignee_type == "ROLE"
      assert Repo.get!(EngineTask, untouched_b.id, prefix: schema_b).assignee_type == nil
    end
  end

  describe "run/0 halts on a hard per-tenant failure" do
    test "a tenant whose physical schema vanished mid-sweep halts the sweep with {:error, {:backfill_failed, tenant_id, reason}}, not a crash" do
      %{tenant_id: vanished_tenant_id, schema_name: vanished_schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0905-backfill-vanished",
          teardown: false
        )

      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

        Repo.delete_all(
          from(r in TenantProvisioning.Registration, where: r.tenant_id == ^vanished_tenant_id)
        )

        Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^vanished_tenant_id))
      end)

      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{vanished_schema_name}" CASCADE))

      assert {:error, {:backfill_failed, ^vanished_tenant_id, _reason}} =
               TaskAssigneeTypeBackfill.run()

      assert %TenantProvisioning.Registration{} =
               Repo.get_by(TenantProvisioning.Registration, tenant_id: vanished_tenant_id)
    end
  end
end
