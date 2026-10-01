defmodule Letflow.ServiceCatalogResolvePinnedVersionTest do
  @moduledoc """
  Resolver unit matrix for ISS-0917's `Letflow.ServiceCatalog.resolve_pinned_version/3`
  (design `lib/letflow/design/iss0917-catalog-service-task-pinned-dispatch.md`
  sections 2.3 / 2.5 / 6.2). See `test/specs/ISS-0917.md` for the case-by-case
  rationale and the fail-first / mutant evidence.

  `async: false`: writes committed rows to the GLOBAL `service_catalog` /
  `service_catalog_versions` tables (same reasoning `service_catalog_test.exs`
  documents). Only lightweight `tenants` rows are inserted (the
  `owner_tenant_id` FK) -- no tenant schema is provisioned, since the resolver
  reads only global tables.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version
  alias Letflow.Identity.Tenant

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  defp unique_service_id do
    "iss0917-rpv-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp insert_tenant! do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("iss0917-rpv"),
          display_name: "ISS-0917 resolver test tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn -> Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id)) end)
    tenant
  end

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register!(overrides) do
    attrs =
      Map.merge(
        %{
          service_id: unique_service_id(),
          endpoint_url: "https://example.test/rpv/v1",
          required_auth: :NONE,
          timeout_ms: 5_000,
          retry_policy: "fixed-3",
          scope: :global
        },
        overrides
      )

    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  defp publish_v2!(service_id) do
    assert {:ok, updated} =
             ServiceCatalog.publish(service_id, "2", %{
               endpoint_url: "https://example.test/rpv/v2",
               required_auth: :NONE,
               timeout_ms: 7_000
             })

    updated
  end

  defp any_tenant_id, do: Ecto.UUID.generate()

  describe "by version_id" do
    test "the live ACTIVE current version resolves with its own technical fields, source :live" do
      entry = register!(%{})

      assert {:ok, resolved} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, entry.version_id},
                 any_tenant_id()
               )

      assert resolved == %{
               service_id: entry.service_id,
               version_id: entry.version_id,
               version: "1",
               endpoint_url: "https://example.test/rpv/v1",
               timeout_ms: 5_000,
               retry_policy: "fixed-3",
               required_auth: :NONE,
               source: :live
             }
    end

    test "a RETIRED current version still resolves (the REQ-373/432 case) -- no status filter" do
      entry = register!(%{})
      assert {:ok, %{status: :RETIRED}} = ServiceCatalog.retire(entry.service_id)

      assert {:ok, resolved} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, entry.version_id},
                 any_tenant_id()
               )

      assert resolved.source == :live
      assert resolved.endpoint_url == "https://example.test/rpv/v1"
      assert resolved.version == "1"
    end

    test "a superseded (archived) version resolves to ITS OWN data, not the live row's" do
      entry = register!(%{})
      v2 = publish_v2!(entry.service_id)
      assert v2.version_id != entry.version_id

      assert {:ok, resolved} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, entry.version_id},
                 any_tenant_id()
               )

      assert resolved.source == :archived
      assert resolved.version_id == entry.version_id
      assert resolved.version == "1"
      assert resolved.endpoint_url == "https://example.test/rpv/v1"
      assert resolved.timeout_ms == 5_000

      # and the new live version resolves to v2 by its own id
      assert {:ok, live} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, v2.version_id},
                 any_tenant_id()
               )

      assert live.source == :live
      assert live.endpoint_url == "https://example.test/rpv/v2"
    end

    test "a version_id that belongs to a DIFFERENT service is :not_found (no cross-service read)" do
      a = register!(%{})
      b = register!(%{endpoint_url: "https://example.test/rpv/other"})
      publish_v2!(b.service_id)

      # b's v1 is now archived under b.service_id; ask for it under a.service_id
      assert {:error, :not_found} =
               ServiceCatalog.resolve_pinned_version(
                 a.service_id,
                 {:version_id, b.version_id},
                 any_tenant_id()
               )
    end

    test "an unknown version_id and a malformed (non-UUID) version_id are both :not_found, never a raise" do
      entry = register!(%{})
      tenant_id = any_tenant_id()

      assert {:error, :not_found} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, Ecto.UUID.generate()},
                 tenant_id
               )

      assert {:error, :not_found} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, "sid"},
                 tenant_id
               )
    end
  end

  describe "by (service_id, version) -- the rebound-pin identity" do
    test "the live current version and an archived version both resolve by version string" do
      entry = register!(%{})
      publish_v2!(entry.service_id)
      tenant_id = any_tenant_id()

      assert {:ok, live} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version, "2"},
                 tenant_id
               )

      assert live.source == :live
      assert live.endpoint_url == "https://example.test/rpv/v2"

      assert {:ok, archived} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version, "1"},
                 tenant_id
               )

      assert archived.source == :archived
      assert archived.version_id == entry.version_id
      assert archived.endpoint_url == "https://example.test/rpv/v1"
    end

    test "a RETIRED current version resolves by version string too" do
      entry = register!(%{})
      assert {:ok, _} = ServiceCatalog.retire(entry.service_id)

      assert {:ok, resolved} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version, "1"},
                 any_tenant_id()
               )

      assert resolved.source == :live
    end

    test "an unknown version string is :not_found" do
      entry = register!(%{})

      assert {:error, :not_found} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version, "9.9.9"},
                 any_tenant_id()
               )
    end
  end

  describe "tenant visibility (INV-1 / INV-5)" do
    test "a global service is visible to any tenant" do
      entry = register!(%{scope: :global})

      for _ <- 1..2 do
        assert {:ok, _} =
                 ServiceCatalog.resolve_pinned_version(
                   entry.service_id,
                   {:version_id, entry.version_id},
                   any_tenant_id()
                 )
      end
    end

    test "a tenant-scoped service resolves for its owner, and ALSO for its archived versions" do
      owner = insert_tenant!()

      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})
      publish_v2!(entry.service_id)

      assert {:ok, live} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version, "2"},
                 owner.id
               )

      assert live.source == :live

      assert {:ok, archived} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, entry.version_id},
                 owner.id
               )

      assert archived.source == :archived
    end

    test "a tenant-scoped service is :not_found for another tenant -- for live, archived and by-version identities -- and indistinguishable (==) from a missing service" do
      owner = insert_tenant!()
      other = insert_tenant!()

      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})
      v2 = publish_v2!(entry.service_id)

      invisible = [
        ServiceCatalog.resolve_pinned_version(
          entry.service_id,
          {:version_id, v2.version_id},
          other.id
        ),
        ServiceCatalog.resolve_pinned_version(
          entry.service_id,
          {:version_id, entry.version_id},
          other.id
        ),
        ServiceCatalog.resolve_pinned_version(entry.service_id, {:version, "1"}, other.id),
        ServiceCatalog.resolve_pinned_version(entry.service_id, {:version, "2"}, other.id)
      ]

      missing =
        ServiceCatalog.resolve_pinned_version(
          unique_service_id(),
          {:version_id, v2.version_id},
          other.id
        )

      assert missing == {:error, :not_found}
      assert Enum.all?(invisible, &(&1 == missing))
    end

    test "narrowing a service's scope to another owner after the fact makes it :not_found (fail closed)" do
      owner = insert_tenant!()
      other = insert_tenant!()
      entry = register!(%{scope: :global})

      assert {:ok, _} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, entry.version_id},
                 owner.id
               )

      entry
      |> Ecto.Changeset.change(%{scope: :tenant, owner_tenant_id: other.id})
      |> Repo.update!()

      assert {:error, :not_found} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, entry.version_id},
                 owner.id
               )
    end

    test "get_for_tenant/2 keeps its three-way visibility behaviour (shared predicate)" do
      owner = insert_tenant!()
      other = insert_tenant!()
      global = register!(%{scope: :global})
      scoped = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      assert {:ok, %Entry{}} = ServiceCatalog.get_for_tenant(global.service_id, other.id)
      assert {:ok, %Entry{}} = ServiceCatalog.get_for_tenant(scoped.service_id, owner.id)
      assert {:error, :not_found} = ServiceCatalog.get_for_tenant(scoped.service_id, other.id)
      assert {:error, :not_found} = ServiceCatalog.get_for_tenant(unique_service_id(), owner.id)
    end
  end

  describe "deleted live row" do
    test "archive rows survive a live-row delete but cannot prove visibility -> :not_found" do
      entry = register!(%{})
      publish_v2!(entry.service_id)

      # The archive row for v1 exists ...
      assert Repo.get(Version, entry.version_id)

      # ... delete only the live row (ServiceCatalog.delete/1 does exactly this,
      # after a tenant-schema referential guard we deliberately avoid here).
      Repo.delete_all(from(e in Entry, where: e.service_id == ^entry.service_id))

      assert Repo.get(Version, entry.version_id)

      assert {:error, :not_found} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, entry.version_id},
                 any_tenant_id()
               )

      assert {:error, :not_found} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version, "1"},
                 any_tenant_id()
               )
    end
  end

  describe "read-only" do
    test "resolution leaves the live row and the archive untouched" do
      entry = register!(%{})
      publish_v2!(entry.service_id)

      live_before = Repo.get!(Entry, entry.service_id)
      archive_before = Repo.all(from(v in Version, where: v.service_id == ^entry.service_id))

      assert {:ok, _} =
               ServiceCatalog.resolve_pinned_version(
                 entry.service_id,
                 {:version_id, entry.version_id},
                 any_tenant_id()
               )

      assert Repo.get!(Entry, entry.service_id) == live_before

      assert Repo.all(from(v in Version, where: v.service_id == ^entry.service_id)) ==
               archive_before
    end
  end
end
