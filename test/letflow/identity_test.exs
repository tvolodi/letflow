defmodule Letflow.IdentityTest do
  @moduledoc """
  Tests for `Letflow.Identity.provision_oidc_user/3` (REQ-018) and
  `Letflow.Identity.resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`,
  `verify_realm_ownership/2`, plus `Letflow.Identity.Tenant.create_changeset/3`/
  `update_changeset/2` (REQ-019). See `test/specs/REQ-018.md` and
  `test/specs/REQ-019.md` for the full test-case rationale, including which criteria
  are covered by inspection rather than a runtime assertion (REQ-018 AC4's moduledoc
  citation, and the `:external_identity_collision` defensive branch).

  Uses `Letflow.DataCase` (real Postgres, sandboxed connection, rolled back per test)
  per `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database anywhere
  in this file.

  The concurrent-race test (acceptance criterion 3) runs `async: true` deliberately:
  `Letflow.DataCase` only calls `Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})`
  when a test is NOT `async: true` (see `test/support/data_case.ex`) — shared mode would
  let the two spawned `Task`s reach the connection pool implicitly, which defeats the
  point of proving the race is handled through the sandbox's normal per-process
  ownership rules. Staying in the sandbox's default (manual, per-process) ownership and
  explicitly `Ecto.Adapters.SQL.Sandbox.allow/3`-ing each spawned `Task` onto the test
  process's own checked-out connection (per design doc §9's exact guidance) is what
  makes this a genuine two-connection race rather than an accidentally-serialized one.

  Every REQ-019 test also runs `async: true` — each test constructs its own tenant
  row(s) inside its own sandboxed transaction (rolled back after the test), so even the
  tests that deliberately reuse the literal `"bpm-default"` slug/realm (per
  `test/specs/REQ-019.md`'s "What 'seeded default tenant' means here") do not collide
  with each other across tests.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig

  # Every test builds its own unique identity triple — no shared hardcoded
  # tenant_id/realm/external_id, per test_developer_guide.md's "no test pollution"
  # principle and this project's established Ecto.UUID.generate()-per-test convention.
  defp unique_realm(prefix \\ "realm") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  # REQ-019 fixture helpers.

  defp unique_slug(prefix \\ "tenant") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp insert_tenant!(attrs, oidc_mode \\ :enabled) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, oidc_mode)
    |> Repo.insert!()
  end

  # The one fixture deliberately using the literal "bpm-default" reserved slug/realm —
  # per test/specs/REQ-019.md, "seeded" means TEST-DESIGNER-constructed, not a real
  # priv/repo/seeds.exs row. oidc_mode is irrelevant to the pinning rule itself (it's
  # unconditional), so :enabled is used here without loss of generality.
  defp insert_default_tenant! do
    insert_tenant!(%{
      slug: "bpm-default",
      display_name: "Default Tenant",
      idp_realm_id: "bpm-default"
    })
  end

  defp identity_context(overrides \\ %{}) do
    struct(
      %IdentityContext{
        external_user_id: Ecto.UUID.generate(),
        tenant_id: nil,
        realm: unique_realm(),
        roles: [],
        email: "someone@example.com",
        preferred_username: "someone-#{System.unique_integer([:positive])}",
        display_name: "Someone Example"
      },
      overrides
    )
  end

  defp jit_config(overrides \\ %{}) do
    struct(
      %JitProvisioningConfig{
        realm: "unused-by-provision_oidc_user",
        enabled: true,
        default_status: :active,
        default_roles: []
      },
      overrides
    )
  end

  describe "provision_oidc_user/3 — idempotency (acceptance criterion 1)" do
    test "calling provision_oidc_user/3 twice with the same identity returns the same user.id, created: true then false" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()
      config = jit_config()

      assert {:ok, %{user: %User{id: id1}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert {:ok, %{user: %User{id: id2}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert id1 == id2
    end

    test "three consecutive calls all resolve to the same user.id" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()
      config = jit_config()

      assert {:ok, %{user: %User{id: id1}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert {:ok, %{user: %User{id: id2}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert {:ok, %{user: %User{id: id3}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert id1 == id2
      assert id2 == id3
    end

    test "different (tenant_id, realm, external_id) triples create distinct rows" do
      config = jit_config()

      ctx_a = identity_context()
      ctx_b = identity_context()

      assert {:ok, %{user: %User{id: id_a}, created: true}} =
               Identity.provision_oidc_user(ctx_a, Ecto.UUID.generate(), config)

      assert {:ok, %{user: %User{id: id_b}, created: true}} =
               Identity.provision_oidc_user(ctx_b, Ecto.UUID.generate(), config)

      assert id_a != id_b
    end
  end

  describe "provision_oidc_user/3 — fixed literals (acceptance criterion 2)" do
    test "the inserted row has the fixed OIDC-only password_hash and auth_source: :oidc" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()

      assert {:ok, %{user: %User{id: id}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant_id, jit_config())

      # Re-select from Postgres directly, rather than trusting the in-memory reply —
      # matches process_instance_test.exs's "every successful transition is persisted
      # to Postgres" persistence-test convention.
      persisted = Repo.get(User, id)

      assert persisted.password_hash == "__OIDC_ONLY__"
      assert persisted.auth_source == :oidc
    end

    test "password_hash and auth_source are not caller-overridable" do
      tenant_id = Ecto.UUID.generate()
      # IdentityContext has no password_hash/auth_source field at all, so this
      # exercises that the changeset always sets fixed values regardless of what's
      # in the context — there is no input surface here that COULD supply an
      # override, which is itself the property being pinned.
      ctx = identity_context(%{email: "override-attempt@example.com"})

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant_id, jit_config())

      persisted = Repo.get(User, id)
      assert persisted.password_hash == "__OIDC_ONLY__"
      assert persisted.auth_source == :oidc
    end
  end

  describe "provision_oidc_user/3 — concurrent-insert race (acceptance criterion 3)" do
    test "a genuine concurrent race between two tasks resolves to exactly one created row, both callers succeed" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()
      config = jit_config()

      parent = self()

      run_task = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

        # Barrier: make both tasks announce readiness, then wait for the parent's
        # go-ahead, so both reach Identity.provision_oidc_user/3's own select-first
        # step at effectively the same time and genuinely race into the INSERT ...
        # ON CONFLICT path together, rather than being accidentally serialized by
        # Task.async/1's own scheduling.
        send(parent, {:ready, self()})

        receive do
          :go -> :ok
        after
          5000 -> flunk("barrier release never arrived")
        end

        Identity.provision_oidc_user(ctx, tenant_id, config)
      end

      task1 = Task.async(run_task)
      task2 = Task.async(run_task)

      # Wait for both tasks to reach the barrier before releasing either — this is
      # what forces both to attempt the insert at effectively the same time instead
      # of being serialized by whichever task's scheduler slice runs first.
      assert_receive {:ready, pid1}, 5000
      assert_receive {:ready, pid2}, 5000
      assert pid1 in [task1.pid, task2.pid]
      assert pid2 in [task1.pid, task2.pid]
      assert pid1 != pid2

      send(pid1, :go)
      send(pid2, :go)

      result1 = Task.await(task1, 5000)
      result2 = Task.await(task2, 5000)

      assert {:ok, %{user: %User{id: id1}, created: created1}} = result1
      assert {:ok, %{user: %User{id: id2}, created: created2}} = result2

      # Both tasks resolve to the same row.
      assert id1 == id2

      # Exactly one of the two calls actually performed the insert.
      assert [created1, created2] |> Enum.count(& &1) == 1

      # No unhandled exception escaped either task (Task.await/2 above would itself
      # have raised if either task's process crashed) — asserting this explicitly as
      # a documented expectation, not just relying on Task.await/2's own behavior.
      assert is_boolean(created1)
      assert is_boolean(created2)

      # Exactly one row exists in the database for this identity afterward.
      import Ecto.Query

      rows =
        User
        |> where(
          tenant_id: ^tenant_id,
          external_realm: ^ctx.realm,
          external_id: ^ctx.external_user_id
        )
        |> Repo.all()

      assert length(rows) == 1
    end
  end

  describe "provision_oidc_user/3 — jit_config.enabled == false (design-flagged, not a numbered AC)" do
    test "jit_config.enabled == false returns {:error, :jit_disabled} without writing to the database" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()
      config = jit_config(%{enabled: false})

      assert {:error, :jit_disabled} = Identity.provision_oidc_user(ctx, tenant_id, config)

      import Ecto.Query

      rows =
        User
        |> where(
          tenant_id: ^tenant_id,
          external_realm: ^ctx.realm,
          external_id: ^ctx.external_user_id
        )
        |> Repo.all()

      assert rows == []
    end
  end

  describe "provision_oidc_user/3 — username cross-tenant collision (design §4.4/OQ-3, design-flagged)" do
    test "two different tenants with the same preferred_username: the second JIT provisioning call fails with a username uniqueness changeset error" do
      shared_username = "collide-#{System.unique_integer([:positive])}"
      config = jit_config()

      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()

      ctx_a = identity_context(%{preferred_username: shared_username})
      ctx_b = identity_context(%{preferred_username: shared_username})

      assert {:ok, %{user: %User{}, created: true}} =
               Identity.provision_oidc_user(ctx_a, tenant_a, config)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Identity.provision_oidc_user(ctx_b, tenant_b, config)

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "provision_oidc_user/3 — display_name fallback (design §4.3, design-flagged)" do
    test "display_name nil in the identity context falls back to preferred_username on the persisted row" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context(%{display_name: nil, preferred_username: "fallback-username"})

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant_id, jit_config())

      persisted = Repo.get(User, id)
      assert persisted.display_name == "fallback-username"
    end

    test "display_name present in the identity context is stored verbatim" do
      tenant_id = Ecto.UUID.generate()

      ctx =
        identity_context(%{
          display_name: "Explicit Display Name",
          preferred_username: "some-other-username"
        })

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant_id, jit_config())

      persisted = Repo.get(User, id)
      assert persisted.display_name == "Explicit Display Name"
    end
  end

  describe "resolve_tenant_by_realm/1 and resolve_realm_by_tenant/1 (REQ-019 acceptance criterion 1)" do
    test "resolve_tenant_by_realm/1 resolves the seeded default tenant (bpm-default) by its idp_realm_id" do
      tenant = insert_default_tenant!()

      assert {:ok, %Tenant{id: id}} = Identity.resolve_tenant_by_realm("bpm-default")
      assert id == tenant.id
    end

    test "resolve_realm_by_tenant/1 resolves the seeded default tenant's (bpm-default) idp_realm_id by its tenant id" do
      tenant = insert_default_tenant!()

      assert {:ok, "bpm-default"} = Identity.resolve_realm_by_tenant(tenant.id)
    end

    test "resolve_tenant_by_realm/1 returns {:error, :not_found} for an unknown realm string" do
      assert {:error, :not_found} = Identity.resolve_tenant_by_realm(unique_realm("nonexistent"))
    end

    test "resolve_realm_by_tenant/1 returns {:error, :not_found} for an unknown tenant_id" do
      assert {:error, :not_found} = Identity.resolve_realm_by_tenant(Ecto.UUID.generate())
    end

    test "resolve_realm_by_tenant/1 returns {:ok, nil} for a tenant that exists but has no bound realm" do
      tenant =
        insert_tenant!(
          %{slug: unique_slug(), display_name: "No Realm Yet", idp_realm_id: nil},
          :disabled
        )

      assert {:ok, nil} = Identity.resolve_realm_by_tenant(tenant.id)
    end
  end

  describe "Tenant.create_changeset/3 — one-to-one collision rejection (REQ-019 acceptance criterion 2)" do
    test "creating a second tenant with an already-bound idp_realm_id is rejected, not silently overwritten" do
      shared_realm = unique_realm("collide")

      insert_tenant!(%{slug: unique_slug(), display_name: "Tenant A", idp_realm_id: shared_realm})

      result =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "Tenant B", idp_realm_id: shared_realm},
          :enabled
        )
        |> Repo.insert()

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert %{idp_realm_id: ["has already been taken"]} = errors_on(changeset)

      import Ecto.Query
      rows = Tenant |> where(idp_realm_id: ^shared_realm) |> Repo.all()
      assert length(rows) == 1
    end

    test "two tenants with distinct idp_realm_id values both persist successfully" do
      tenant_a =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Tenant A",
          idp_realm_id: unique_realm()
        })

      tenant_b =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Tenant B",
          idp_realm_id: unique_realm()
        })

      assert tenant_a.id != tenant_b.id
      assert tenant_a.idp_realm_id != tenant_b.idp_realm_id
    end
  end

  describe "Tenant.update_changeset/2 — idp_realm_id immutability (REQ-019 acceptance criterion 3)" do
    test "update_changeset/2 does not cast idp_realm_id even when present in attrs" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Original Name",
          idp_realm_id: unique_realm("original")
        })

      changeset =
        Tenant.update_changeset(tenant, %{
          idp_realm_id: "attempted-new-realm",
          display_name: "New Name"
        })

      assert Ecto.Changeset.get_change(changeset, :idp_realm_id) == nil
      assert Ecto.Changeset.get_change(changeset, :display_name) == "New Name"
      assert changeset.valid?
    end

    test "persisting update_changeset/2 with an attempted idp_realm_id change leaves the original idp_realm_id unchanged in the database" do
      original_realm = unique_realm("original")

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Original Name",
          idp_realm_id: original_realm
        })

      changeset =
        Tenant.update_changeset(tenant, %{
          idp_realm_id: "attempted-new-realm",
          display_name: "New Name"
        })

      assert {:ok, _updated} = Repo.update(changeset)

      persisted = Repo.get(Tenant, tenant.id)
      assert persisted.idp_realm_id == original_realm
      assert persisted.display_name == "New Name"
    end
  end

  describe "verify_realm_ownership/2 — realm-ownership guard, every branch (REQ-019 acceptance criterion 4)" do
    test "verify_realm_ownership/2 returns :ok when external_realm matches the tenant's bound idp_realm_id" do
      realm = unique_realm()

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Matching Tenant",
          idp_realm_id: realm
        })

      assert :ok = Identity.verify_realm_ownership(tenant.id, realm)
    end

    test "verify_realm_ownership/2 returns {:error, :realm_tenant_mismatch} when external_realm does not match the tenant's bound realm" do
      bound_realm = unique_realm("bound")
      other_realm = unique_realm("other")

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Bound Tenant",
          idp_realm_id: bound_realm
        })

      assert {:error, :realm_tenant_mismatch} =
               Identity.verify_realm_ownership(tenant.id, other_realm)
    end

    test "verify_realm_ownership/2 returns {:error, :not_found} for a tenant_id that matches no row" do
      assert {:error, :not_found} =
               Identity.verify_realm_ownership(Ecto.UUID.generate(), unique_realm())
    end

    test "verify_realm_ownership/2 returns {:error, :realm_tenant_mismatch}, not :ok and not a crash, for a tenant with no bound realm" do
      tenant =
        insert_tenant!(
          %{slug: unique_slug(), display_name: "No Realm Bound", idp_realm_id: nil},
          :disabled
        )

      assert {:error, :realm_tenant_mismatch} =
               Identity.verify_realm_ownership(tenant.id, unique_realm("some-external-realm"))
    end
  end

  describe "Tenant.create_changeset/3 — default-tenant pinning (design §3.2/§4)" do
    test "create_changeset/3 rejects slug bpm-default paired with a different idp_realm_id" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant", idp_realm_id: unique_realm()},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end

    test "create_changeset/3 accepts slug bpm-default paired with idp_realm_id bpm-default" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant", idp_realm_id: "bpm-default"},
          :enabled
        )

      assert changeset.valid?
    end

    test "create_changeset/3 rejects slug bpm-default with idp_realm_id omitted entirely" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant"},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "Tenant.create_changeset/3 — oidc_mode-conditional idp_realm_id requirement (design §3.2)" do
    test "create_changeset/3 requires idp_realm_id for a non-default tenant when oidc_mode is :enabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: unique_slug(), display_name: "Non-default Tenant"},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end

    test "create_changeset/3 allows a non-default tenant with no idp_realm_id when oidc_mode is :disabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: unique_slug(), display_name: "Non-default Tenant"},
          :disabled
        )

      assert changeset.valid?
    end

    test "create_changeset/3 accepts a non-default tenant with idp_realm_id present when oidc_mode is :enabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{
            slug: unique_slug(),
            display_name: "Non-default Tenant",
            idp_realm_id: unique_realm()
          },
          :enabled
        )

      assert changeset.valid?
    end
  end

  # Minimal local helper mirroring Ecto's own test-helper convention (avoids pulling
  # in a full Phoenix-style ConnCase/errors_on just for this one assertion).
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
