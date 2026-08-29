defmodule Letflow.WebhooksTest do
  @moduledoc """
  Tests for REQ-181 -- `Letflow.Webhooks` (context module) and
  `Letflow.Webhooks.Subscription` (schema). See `test/specs/REQ-181.md` for
  the full acceptance-criterion -> test-case mapping and rationale. Design
  authority: `lib/letflow/design/req181-webhooks-core.md`. Implementation
  authority: `lib/letflow/webhooks.ex`/`lib/letflow/webhooks/subscription.ex`,
  which already passed SECURITY-REVIEWER and REVIEWER.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Each test that needs real rows provisions a real tenant schema via
  `Letflow.TenantFixture.provisioned_tenant!/1` (real `CREATE SCHEMA` +
  `TenantProvisioning.replay_migrations/1`), mirroring
  `test/letflow/dlq_test.exs`'s own established pattern for this class of
  context-module test (REQ-181 mirrors REQ-176's shape). `async: false` for
  the same reason every other tenant-fixture-using test file in this
  codebase sets it (real schema creation/teardown against one shared
  Postgres instance).

  `lib/letflow/routers/webhooks.ex` (REQ-182) now fronts this context module
  with the route/controller layer, but every test below still calls the
  context module's functions directly -- the same way `test/letflow/dlq_test.exs`
  exercises `Letflow.Dlq` directly even after `lib/letflow/routers/dlq.ex`
  (REQ-178) was added. REQ-182's own HTTP-layer tests belong to that
  requirement's test file, not here.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Webhooks
  alias Letflow.Webhooks.Subscription

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req181-webhooks") do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-181 Webhooks Test Tenant"
    )
  end

  defp create!(schema_name, attrs \\ %{}) do
    base = %{target_url: "https://example.test/hook"}
    {:ok, result} = Webhooks.create(Map.merge(base, attrs), prefix: schema_name)
    result
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- webhook_subscriptions lives inside the tenant's own Postgres
  # schema, with a tenant_id column retained (Decision B / decision 0003)
  # ---------------------------------------------------------------------------------

  describe "AC1: webhook_subscriptions migration -- schema-per-tenant with tenant_id retained" do
    test "the table exists in the tenant's own schema, carries a tenant_id column, and is absent from public" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{rows: tenant_columns} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'webhook_subscriptions'",
          [schema_name]
        )

      column_names = Enum.map(tenant_columns, fn [name] -> name end)
      assert "tenant_id" in column_names
      assert "id" in column_names
      assert "status" in column_names
      assert "secret_hash" in column_names

      # The isolation boundary is the Postgres schema, not the tenant_id
      # column (design §1) -- confirmed by there being no
      # webhook_subscriptions table in `public` at all.
      %{rows: public_rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables " <>
            "WHERE table_schema = 'public' AND table_name = 'webhook_subscriptions'"
        )

      assert public_rows == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- create/2's secret handling: generated-once plaintext, hash-only
  # storage, never exposed again by list/1 or get
  # ---------------------------------------------------------------------------------

  describe "AC2: create/2 generates a secret, stores only its hash, returns plaintext once" do
    test "no secret supplied -- generates one, stores only the SHA-256 hash, returns hmac_secret_once" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{subscription: subscription, hmac_secret_once: plaintext} = create!(schema_name)

      assert is_binary(plaintext)
      assert plaintext != ""

      expected_hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
      assert subscription.secret_hash == expected_hash
      assert subscription.secret_hash != plaintext

      reloaded = Repo.get!(Subscription, subscription.id, prefix: schema_name)
      assert reloaded.secret_hash == expected_hash
    end
  end

  describe "AC2: list/1 and get (via delete's not-found path) never expose the plaintext or hmac_secret_once" do
    test "a subsequent list/1 of the same subscription carries no plaintext and no hmac_secret_once key" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{subscription: subscription, hmac_secret_once: plaintext} = create!(schema_name)

      {:ok, [listed]} = Webhooks.list(prefix: schema_name)

      assert listed.id == subscription.id
      refute Map.has_key?(Map.from_struct(listed), :hmac_secret_once)
      assert listed.secret_hash != plaintext
      assert listed.secret_hash == subscription.secret_hash
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- update/3's status/is_active reconciliation (design §3.3's table)
  # ---------------------------------------------------------------------------------

  describe "AC3: update/3 reconciles status/is_active to one stored PAUSED state" do
    test "%{status: \"PAUSED\"} results in status PAUSED on readback" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{subscription: subscription} = create!(schema_name)

      assert {:ok, updated} =
               Webhooks.update(subscription.id, %{status: "PAUSED"}, prefix: schema_name)

      assert updated.status == :PAUSED
      assert %DateTime{} = updated.paused_at

      reloaded = Repo.get!(Subscription, subscription.id, prefix: schema_name)
      assert reloaded.status == :PAUSED
    end

    test "%{is_active: false} results in status PAUSED on readback" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{subscription: subscription} = create!(schema_name)

      assert {:ok, updated} =
               Webhooks.update(subscription.id, %{is_active: false}, prefix: schema_name)

      assert updated.status == :PAUSED
      assert %DateTime{} = updated.paused_at

      reloaded = Repo.get!(Subscription, subscription.id, prefix: schema_name)
      assert reloaded.status == :PAUSED
    end

    test "agreeing pair %{status: \"PAUSED\", is_active: false} results in PAUSED" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{subscription: subscription} = create!(schema_name)

      assert {:ok, updated} =
               Webhooks.update(
                 subscription.id,
                 %{status: "PAUSED", is_active: false},
                 prefix: schema_name
               )

      assert updated.status == :PAUSED
    end

    test "agreeing pair %{status: \"ACTIVE\", is_active: true} results in ACTIVE and clears paused_at" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{subscription: subscription} = create!(schema_name)

      {:ok, _paused} = Webhooks.update(subscription.id, %{status: "PAUSED"}, prefix: schema_name)

      assert {:ok, updated} =
               Webhooks.update(
                 subscription.id,
                 %{status: "ACTIVE", is_active: true},
                 prefix: schema_name
               )

      assert updated.status == :ACTIVE
      assert is_nil(updated.paused_at)
    end

    test "disagreeing pair %{status: \"ACTIVE\", is_active: false} returns invalid_status and does not write" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{subscription: subscription} = create!(schema_name)

      assert {:error, :invalid_status} =
               Webhooks.update(
                 subscription.id,
                 %{status: "ACTIVE", is_active: false},
                 prefix: schema_name
               )

      reloaded = Repo.get!(Subscription, subscription.id, prefix: schema_name)
      assert reloaded.status == :ACTIVE
    end

    test "single key %{status: \"ACTIVE\"} alone results in ACTIVE" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{subscription: subscription} = create!(schema_name)
      {:ok, _paused} = Webhooks.update(subscription.id, %{status: "PAUSED"}, prefix: schema_name)

      assert {:ok, updated} =
               Webhooks.update(subscription.id, %{status: "ACTIVE"}, prefix: schema_name)

      assert updated.status == :ACTIVE
    end

    test "single key %{is_active: true} alone results in ACTIVE" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{subscription: subscription} = create!(schema_name)
      {:ok, _paused} = Webhooks.update(subscription.id, %{status: "PAUSED"}, prefix: schema_name)

      assert {:ok, updated} =
               Webhooks.update(subscription.id, %{is_active: true}, prefix: schema_name)

      assert updated.status == :ACTIVE
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- list/1 is tenant-scoped
  # ---------------------------------------------------------------------------------

  describe "AC4: list/1 is tenant-scoped" do
    test "a subscription created under tenant A is absent from tenant B's list/1" do
      %{schema_name: schema_a} = provisioned_tenant("req181-webhooks-a")
      %{schema_name: schema_b} = provisioned_tenant("req181-webhooks-b")

      %{subscription: subscription_a} = create!(schema_a)

      {:ok, items_a} = Webhooks.list(prefix: schema_a)
      {:ok, items_b} = Webhooks.list(prefix: schema_b)

      assert Enum.map(items_a, & &1.id) == [subscription_a.id]
      assert items_b == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- delete/2 removes the row; a second delete returns not-found, not
  # a duplicate success
  # ---------------------------------------------------------------------------------

  describe "AC5: delete/2 removes the subscription; a second delete is not-found" do
    test "list/1 excludes the deleted subscription, and deleting again returns not_found" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{subscription: subscription} = create!(schema_name)

      assert {:ok, deleted} = Webhooks.delete(subscription.id, prefix: schema_name)
      assert deleted.id == subscription.id

      {:ok, items} = Webhooks.list(prefix: schema_name)
      assert items == []

      assert {:error, :not_found} = Webhooks.delete(subscription.id, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- Letflow.Webhooks and Letflow.Webhooks.Subscription are pure
  # context/schema modules, with no route or controller-shaped constructs of
  # their own
  # ---------------------------------------------------------------------------------

  describe "AC6: Letflow.Webhooks core itself has no route or controller-shaped constructs" do
    # NOTE: an earlier revision of this test additionally asserted no router
    # file existed anywhere for `webhooks` in `lib/letflow/routers` -- that
    # premise is now obsolete: REQ-182 (a separate, later, gate-approved
    # requirement) correctly and intentionally added
    # `lib/letflow/routers/webhooks.ex` as the route layer atop this context
    # module. Same class of staleness as REQ-176's AC6 test breaking on
    # REQ-178's `lib/letflow/routers/dlq.ex` (see docs/anti-patterns.md and
    # `test/letflow/dlq_test.exs`'s own AC6 describe block, fixed the same
    # way). REQ-181's actual scope was never "no webhooks route ever exists"
    # -- it was "this context/schema module itself contains no route or
    # controller-shaped constructs" (design authority
    # `lib/letflow/design/req181-webhooks-core.md`). This test is scoped to
    # that narrower, still-true claim: `lib/letflow/webhooks.ex` and
    # `lib/letflow/webhooks/subscription.ex` remain pure context/schema
    # modules with no `use Plug.Router`, no controller `use`, and no route
    # macro defined directly in either file. It says nothing about
    # `lib/letflow/routers/`, which is REQ-182's territory.
    test "neither Letflow.Webhooks nor Letflow.Webhooks.Subscription references Plug/Router-shaped constructs" do
      for path <- ["lib/letflow/webhooks.ex", "lib/letflow/webhooks/subscription.ex"] do
        source = File.read!(Path.join(File.cwd!(), path))
        refute source =~ ~r/use\s+Plug\.Router/, "#{path} unexpectedly uses Plug.Router"
        refute source =~ ~r/use\s+\w*Web,\s*:controller/, "#{path} unexpectedly is a controller"
        refute source =~ ~r/\bget\s+"\//, "#{path} unexpectedly defines a route"
      end
    end
  end
end
