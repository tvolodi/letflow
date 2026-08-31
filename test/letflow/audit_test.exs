defmodule Letflow.AuditTest do
  @moduledoc """
  Tests for `Letflow.Audit` (REQ-195) -- the storage/chaining primitives
  themselves: DB-level immutability (AC1), tenant scoping (AC4), chain
  linkage including the first-entry-null case (AC5), and the
  recompute-based `verify_chain/2` (AC6, the single most important test in
  this requirement -- see this module's own moduledoc for why R-Co's own
  linkage-only check is the defect this must not repeat). AC2/AC3 (real
  before/after capture on definition/instance/task operations, and
  audit-write-failure rollback) are covered in
  `test/letflow/audit_capture_test.exs`, against the actual covered context
  functions rather than `Letflow.Audit` directly.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Self-contained: provisions its own tenant schema(s), does not share
  fixtures with any other test file (DIRECTIVE T-4).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req195-audit"),
        display_name: "REQ-195 Audit Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp base_attrs(overrides \\ []) do
    Map.merge(
      %{
        actor_id: nil,
        action: "definition.create",
        resource_type: "definition",
        resource_id: Ecto.UUID.generate(),
        before_state: nil,
        after_state: %{"name" => "sample", "version" => "1.0.0"},
        trace_id: nil
      },
      Map.new(overrides)
    )
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- DB-level immutability, going around the Ecto schema entirely
  # (raw SQL, not Repo.update/1's changeset path).
  # ---------------------------------------------------------------------------------

  describe "AC1 -- immutability enforced by the database" do
    test "a raw UPDATE against a persisted row is rejected by a trigger" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{id: id}} = Audit.insert_entry(Repo, base_attrs(), schema_name)

      assert_raise Postgrex.Error, ~r/audit_entries is immutable/, fn ->
        Repo.query!(
          ~s(UPDATE "#{schema_name}".audit_entries SET action = 'tampered' WHERE id = $1),
          [Ecto.UUID.dump!(id)]
        )
      end
    end

    test "a raw DELETE against a persisted row is rejected by a trigger" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{id: id}} = Audit.insert_entry(Repo, base_attrs(), schema_name)

      assert_raise Postgrex.Error, ~r/audit_entries is immutable/, fn ->
        Repo.query!(~s(DELETE FROM "#{schema_name}".audit_entries WHERE id = $1), [
          Ecto.UUID.dump!(id)
        ])
      end

      # The row survived the rejected DELETE -- immutability, not merely an
      # error being raised for an unrelated reason.
      assert Repo.get(Entry, id, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- tenant scoping.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- tenant-scoped rows" do
    test "a row written under tenant A is not visible to a query scoped to tenant B" do
      %{schema_name: schema_a} = provisioned_tenant()
      %{schema_name: schema_b} = provisioned_tenant()

      assert {:ok, %Entry{id: id_a}} = Audit.insert_entry(Repo, base_attrs(), schema_a)

      assert Repo.get(Entry, id_a, prefix: schema_a)
      assert Repo.get(Entry, id_a, prefix: schema_b) == nil
      assert Repo.all(Entry, prefix: schema_b) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- prev_chain_hash linkage, including the first-entry-null case.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- chain linkage" do
    test "the first entry in a tenant's chain has a null prev_chain_hash" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{prev_chain_hash: nil}} =
               Audit.insert_entry(Repo, base_attrs(), schema_name)
    end

    test "each subsequent entry's prev_chain_hash equals the immediately-prior entry's chain_hash" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{chain_hash: hash_1, prev_chain_hash: nil}} =
               Audit.insert_entry(Repo, base_attrs(action: "definition.create"), schema_name)

      assert {:ok, %Entry{chain_hash: hash_2, prev_chain_hash: ^hash_1}} =
               Audit.insert_entry(Repo, base_attrs(action: "definition.activate"), schema_name)

      assert {:ok, %Entry{prev_chain_hash: ^hash_2}} =
               Audit.insert_entry(Repo, base_attrs(action: "definition.deprecate"), schema_name)

      assert {:ok, :valid} = Audit.verify_chain(schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- the critical fix: verify_chain/2 RECOMPUTES, it does not just check
  # linkage. This is this requirement's single most important test.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- verify_chain/2 recomputes each entry's hash, catching tampered content" do
    test "an untampered chain of several entries verifies :valid" do
      %{schema_name: schema_name} = provisioned_tenant()

      for n <- 1..4 do
        assert {:ok, _entry} =
                 Audit.insert_entry(
                   Repo,
                   base_attrs(resource_id: "res-#{n}", after_state: %{"n" => n}),
                   schema_name
                 )
      end

      assert {:ok, :valid} = Audit.verify_chain(schema_name)
    end

    test "modifying a persisted after_state directly, leaving both hash columns untouched, is caught as a hash_mismatch" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{id: id_1}} =
               Audit.insert_entry(
                 Repo,
                 base_attrs(resource_id: "res-1", after_state: %{"name" => "original"}),
                 schema_name
               )

      assert {:ok, %Entry{id: id_2}} =
               Audit.insert_entry(
                 Repo,
                 base_attrs(resource_id: "res-2", after_state: %{"name" => "second"}),
                 schema_name
               )

      # Adversarially bypass the immutability trigger (§2/AC1) the same way a
      # superuser incident-response tamper would -- disable the trigger for
      # this connection, mutate after_state directly via raw SQL, re-enable
      # it. chain_hash/prev_chain_hash are deliberately left untouched, which
      # is exactly the case R-Co's own linkage-only check cannot detect (see
      # Letflow.Audit's moduledoc).
      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries DISABLE TRIGGER ALL))

      Repo.query!(
        ~s(UPDATE "#{schema_name}".audit_entries SET after_state = $1 WHERE id = $2),
        [%{"name" => "TAMPERED"}, Ecto.UUID.dump!(id_1)]
      )

      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries ENABLE TRIGGER ALL))

      # Confirm the tamper actually landed (sanity check on the test itself).
      tampered = Repo.get!(Entry, id_1, prefix: schema_name)
      assert tampered.after_state == %{"name" => "TAMPERED"}
      # chain_hash was NOT recomputed after the direct mutation -- still the
      # original digest over the original content.

      assert {:error, {:hash_mismatch, ^id_1}} = Audit.verify_chain(schema_name)

      # Confirms this is genuinely a *recompute* check and not merely
      # "any chain with 2 rows always fails": id_2 is never reached because
      # verify_chain/2 stops at the first bad entry (id_1), which is itself
      # the assertion above. A chain-linkage-only check (R-Co's own defect)
      # would instead report id_2 as :chain_broken, or nothing at all, since
      # id_1's own stored chain_hash/prev_chain_hash pair was left internally
      # self-consistent by the tamper -- only recomputing from content
      # detects it.
      refute match?({:error, {:chain_broken, ^id_2}}, Audit.verify_chain(schema_name))
    end

    test "a deleted middle entry breaks the chain linkage, reported as chain_broken (not hash_mismatch)" do
      %{schema_name: schema_name} = provisioned_tenant()

      # Note: prev_chain_hash is itself one of the 11 hashed fields (design
      # §5.1 field 11) -- directly overwriting it on a persisted row (without
      # also recomputing that row's own chain_hash to match) is a content
      # tamper, caught as hash_mismatch, not chain_broken (see the test
      # above). A genuine chain_broken case -- linkage disrupted without any
      # single row's own stored chain_hash disagreeing with its own stored
      # content -- is a deleted-and-never-reinserted entry: id_3's own row is
      # completely untouched, but the entry its prev_chain_hash points to no
      # longer exists between id_1 and id_3.
      assert {:ok, %Entry{}} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-1"), schema_name)

      assert {:ok, %Entry{id: id_2}} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-2"), schema_name)

      assert {:ok, %Entry{id: id_3}} =
               Audit.insert_entry(Repo, base_attrs(resource_id: "res-3"), schema_name)

      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries DISABLE TRIGGER ALL))

      Repo.query!(~s(DELETE FROM "#{schema_name}".audit_entries WHERE id = $1), [
        Ecto.UUID.dump!(id_2)
      ])

      Repo.query!(~s(ALTER TABLE "#{schema_name}".audit_entries ENABLE TRIGGER ALL))

      assert {:error, {:chain_broken, ^id_3}} = Audit.verify_chain(schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- resource_id's column type (design §1.2 Decision 1): a non-uuid
  # resource identifier round-trips cleanly.
  # ---------------------------------------------------------------------------------

  describe "AC9 -- resource_id accepts a non-uuid identifier" do
    test "writes and reads back an audit entry whose resource_id is not a uuid" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Entry{resource_id: "tenant_role:approver"}} =
               Audit.insert_entry(
                 Repo,
                 base_attrs(
                   action: "tenant_role.upsert",
                   resource_type: "tenant_role",
                   resource_id: "tenant_role:approver"
                 ),
                 schema_name
               )
    end
  end
end
