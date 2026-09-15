defmodule Letflow.PublicReadFixtureSupport.Migration do
  @moduledoc """
  Test-only tenant-scoped migration for `Letflow.PublicReadFixtureSupport.Resource`
  (REQ-352 §10). Deliberately lives under `test/support/`, not
  `priv/repo/migrations/` -- it is never picked up by a plain `mix ecto.migrate`
  run and is never added to `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s
  real manifest, matching the established shape of
  `Letflow.TenantProvisioning.MigrationFixture` (REQ-022) and
  `test/support/req076_broken_migration_fixture.ex`.

  Guarded by `if prefix()` (the same required guard every real tenant-scoped
  migration follows, per `test/support/req022_migration_fixture.ex`'s own
  moduledoc) so this file is harmless even if it were ever run with no
  `:prefix`.

  Run via `Letflow.TenantProvisioning.replay_migrations/2`'s custom
  `migration_source` argument, ON TOP OF a tenant already fully provisioned by
  `Letflow.TenantFixture.provisioned_tenant!(template: :replay)` -- see
  `Letflow.PublicReadFixtureSupport.provision_tenant!/0`. Version `1` is used
  (not a real timestamp) precisely because `test/letflow/tenant_provisioning_test.exs`
  already establishes that pattern for exactly this purpose (a version number
  guaranteed not to collide with the real manifest's timestamp-shaped versions).
  """

  use Ecto.Migration

  def change do
    if prefix() do
      create table(:public_read_fixture_resources, primary_key: false, prefix: prefix()) do
        add(:id, :binary_id, primary_key: true)
        add(:publishable, :boolean, null: false, default: true)
      end
    end
  end
end

defmodule Letflow.PublicReadFixtureSupport.Resource do
  @moduledoc """
  Minimal tenant-scoped Ecto schema backing the test-only `"public-read-fixture"`
  kind (REQ-352 design §10). Lives entirely under `test/support/` -- never
  referenced from `lib/`, never part of the shipped application.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "public_read_fixture_resources" do
    field(:publishable, :boolean, default: true)
  end

  @type t :: %__MODULE__{id: Ecto.UUID.t(), publishable: boolean()}
end

defmodule Letflow.PublicReadFixtureSupport.Projection do
  @moduledoc """
  Test-only `Letflow.PublicRead.Projection` implementation (REQ-352 design
  §10) for the `"public-read-fixture"` (and, for AC-4's kind-mismatch case,
  `"public-read-fixture-mismatch"`) kind registered in `config/test.exs`.

  `project/2` returns `{:ok, %{"label" => "fixture"}}` when the resource is
  `publishable`, `:skip` otherwise -- proving case 7 of the ten-case refusal
  table (design §7) without naming any real vertical.
  """

  @behaviour Letflow.PublicRead.Projection

  alias Letflow.PublicReadFixtureSupport.Resource

  @impl true
  def schema, do: Resource

  @impl true
  def project(%Resource{publishable: true}, _handle_meta), do: {:ok, %{"label" => "fixture"}}
  def project(%Resource{publishable: false}, _handle_meta), do: :skip
end

defmodule Letflow.PublicReadFixtureSupport do
  @moduledoc """
  Test helpers for REQ-352's acceptance-criteria tests: provisions a real
  tenant carrying the fixture table (`Letflow.PublicReadFixtureSupport.Migration`
  on top of `Letflow.TenantFixture`'s real replayed manifest), inserts fixture
  resource rows, and issues real handles through the shipped writer
  (`Letflow.PublicRead.issue_handle/4` -- never a second, local issue path).

  `template: :replay` is required (not the default `:clone`) because the
  cloned template schema is built once from `tenant_scoped_migrations/0`'s
  real manifest alone and does not carry this test-only fixture table --
  only a freshly replayed schema can then have the fixture migration layered
  on top of it.
  """

  alias Letflow.PublicRead
  alias Letflow.PublicReadFixtureSupport.Migration
  alias Letflow.PublicReadFixtureSupport.Resource
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @kind "public-read-fixture"
  @mismatched_kind "public-read-fixture-mismatch"
  @fixture_migration_version 1

  @doc "The kind string registered in `config/test.exs` against this fixture's projection."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  A SECOND kind string, also registered in `config/test.exs` against the same
  fixture projection -- exists solely so AC-4's kind-mismatch case (design §7
  case 5) can be exercised through a real HTTP request whose PATH kind is
  registered but differs from the HANDLE's own stored `kind` field, rather
  than only through a direct `Letflow.PublicRead.resolve/2` call.
  """
  @spec mismatched_kind() :: String.t()
  def mismatched_kind, do: @mismatched_kind

  @doc """
  Provisions a real tenant schema (`Letflow.TenantFixture.provisioned_tenant!/1`,
  `template: :replay`) and layers the fixture resource table on top of it via
  `Letflow.TenantProvisioning.replay_migrations/2`'s custom `migration_source`
  argument. Returns the same map `provisioned_tenant!/1` does.
  """
  @spec provision_tenant!() :: TenantFixture.tenant_fixture()
  def provision_tenant! do
    fixture = TenantFixture.provisioned_tenant!(template: :replay)

    {:ok, _applied_versions} =
      TenantProvisioning.replay_migrations(fixture.tenant_id, [
        {@fixture_migration_version, Migration}
      ])

    fixture
  end

  @doc """
  Inserts one fixture resource row into `prefix`'s schema. Every call site in
  this test suite passes `attrs` explicitly (e.g. `%{publishable: false}` for
  AC-4's "resource unpublishable" case, design §7 case 7) -- `attrs` is
  therefore a required argument here, not a defaulted one, so this helper
  carries no default value that could go dead (`docs/anti-patterns.md`'s "A
  test helper's default argument goes dead..." entry, ISS-0069).
  """
  @spec insert_resource!(prefix :: String.t(), attrs :: %{optional(:publishable) => boolean()}) ::
          Resource.t()
  def insert_resource!(prefix, attrs) do
    %Resource{id: Ecto.UUID.generate(), publishable: Map.fetch!(attrs, :publishable)}
    |> Ecto.Changeset.change()
    |> Repo.insert!(prefix: prefix)
  end

  @doc """
  Issues a real handle through `Letflow.PublicRead.issue_handle/4` (the
  shipped writer -- no second, local issue path) for `{tenant_id, kind,
  resource_id}`. Returns the plaintext handle.
  """
  @spec issue_handle!(
          tenant_id :: Ecto.UUID.t(),
          resource_id :: Ecto.UUID.t(),
          kind :: String.t(),
          opts :: PublicRead.issue_opts()
        ) :: String.t()
  def issue_handle!(tenant_id, resource_id, kind \\ @kind, opts \\ []) do
    {:ok, %{handle: plaintext}} = PublicRead.issue_handle(tenant_id, kind, resource_id, opts)
    plaintext
  end

  @doc """
  Marks a previously-issued handle (by its plaintext) revoked -- design §7
  case 3. `Letflow.PublicRead` ships no revoke API yet (out of scope for
  REQ-352), so this reaches the schema directly, exactly the way this test
  support module is allowed to but application code is not.
  """
  @spec revoke_handle!(plaintext :: String.t()) :: :ok
  def revoke_handle!(plaintext) do
    handle_hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)

    Repo.get_by!(Letflow.PublicRead.Handle, handle_hash: handle_hash)
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
    |> Repo.update!()

    :ok
  end

  @doc "A well-formed, never-issued handle -- design §7 case 2."
  @spec unknown_handle() :: String.t()
  def unknown_handle do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
