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
  context-module test (REQ-181 mirrors REQ-176's shape).

  `async: true` (ISS-0113 / ISS-0423,
  `lib/letflow/design/iss0113-tenant-fixture-sandbox-restore-opt-in.md`) -- this file
  was independently verified, by direct read, against that design's §3 three-mechanism
  classification procedure (no self-checkout, no concurrent multi-process DB access, no
  second provisioning call per test) and cleared safe to convert from the
  `async: false` every other `TenantFixture`-calling test file in this codebase still
  uses today. No opt-in flag is needed on the `provisioned_tenant!/1` call itself --
  see that function's own moduledoc for why its existing, unconditional
  `Sandbox.mode(Letflow.Repo, :auto)` is already sufficient.

  `lib/letflow/routers/webhooks.ex` (REQ-182) now fronts this context module
  with the route/controller layer, but every test below still calls the
  context module's functions directly -- the same way `test/letflow/dlq_test.exs`
  exercises `Letflow.Dlq` directly even after `lib/letflow/routers/dlq.ex`
  (REQ-178) was added. REQ-182's own HTTP-layer tests belong to that
  requirement's test file, not here.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Webhooks
  alias Letflow.Webhooks.Delivery
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
    # Use a literal public IP so SSRF validation passes without a DNS round-trip
    # (REQ-204 blocks any hostname that fails to resolve, including .test TLDs).
    base = %{target_url: "https://93.184.216.34/hook"}
    {:ok, result} = Webhooks.create(Map.merge(base, attrs), prefix: schema_name)
    result
  end

  # REQ-184 -- inserts a `webhook_delivery_attempts` row directly (bypassing
  # `deliver/3`, which is REQ-183's territory and untouched by this
  # requirement), mirroring the exact insert shape `attempt_loop/7` uses.
  defp insert_delivery!(schema_name, tenant_id, subscription_id, attrs \\ %{}) do
    base = %{
      tenant_id: tenant_id,
      delivery_id: Ecto.UUID.generate(),
      subscription_id: subscription_id,
      event_type: "instance.completed",
      status: :SUCCESS,
      http_status_code: 200,
      attempted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      attempt_count: 1,
      max_attempts: 4,
      last_error: nil
    }

    {:ok, delivery} =
      %Delivery{}
      |> Delivery.insert_changeset(Map.merge(base, attrs))
      |> Repo.insert(prefix: schema_name)

    delivery
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

      # secret_hash still exists as a real DB column (the REQ-190 migration blanks
      # it to NULL, deliberately does not drop it -- design §5.1), but is
      # superseded by secret_ref/secret_key_id (REQ-190, 0016 §F) as of this
      # requirement's own migration -- see AC2 below for the current write path.
      assert "secret_hash" in column_names
      assert "secret_ref" in column_names
      assert "secret_key_id" in column_names

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

  describe "AC2: create/2 generates a secret, stores it via the secrets table (not a hash), returns plaintext once" do
    # REQ-190 (0016 §F) superseded this AC's original hashed-secret storage: a
    # one-way SHA-256 hash cannot supply the key material HMAC-SHA256 signing
    # needs, so create/2 now writes the plaintext through Letflow.Secrets.put/2
    # and stores only the resulting secret_ref/secret_key_id reference -- never a
    # hash, never the plaintext itself. Confirmed expected fallout of 0016 §F by
    # ELIXIR-DEV/REVIEWER/SECURITY-REVIEWER (not a regression); see
    # test/specs/REQ-190.md's "webhooks_test.exs staleness fix" section and
    # test/letflow/secrets_test.exs's AC9 for the full round-trip proof (create/2
    # -> Secrets.put/2 -> Secrets.resolve/2 recovers the identical plaintext).
    test "no secret supplied -- generates one, stores it via secret_ref/secret_key_id, never a plaintext-derived hash" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{subscription: subscription, hmac_secret_once: plaintext} = create!(schema_name)

      assert is_binary(plaintext)
      assert plaintext != ""

      assert is_binary(subscription.secret_ref)
      assert String.starts_with?(subscription.secret_ref, "sec://tenant/")
      assert is_integer(subscription.secret_key_id) and subscription.secret_key_id > 0

      reloaded = Repo.get!(Subscription, subscription.id, prefix: schema_name)
      assert reloaded.secret_ref == subscription.secret_ref
      assert reloaded.secret_key_id == subscription.secret_key_id

      # The literal REQ-190 assertion: no plaintext secret persists in
      # webhook_subscriptions. secret_hash has no field on this schema at all
      # (Ecto.Schema tolerates an unmapped column silently), so this reads the
      # raw column directly rather than via the struct.
      %{rows: [[secret_hash]]} =
        Repo.query!(
          ~s(SELECT secret_hash FROM "#{schema_name}".webhook_subscriptions WHERE id = $1),
          [Ecto.UUID.dump!(subscription.id)]
        )

      assert secret_hash == nil
    end
  end

  describe "AC2: list/1 and get (via delete's not-found path) never expose the plaintext or hmac_secret_once" do
    test "a subsequent list/1 of the same subscription carries no plaintext, no hmac_secret_once key, and no secret_hash field at all" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{subscription: subscription, hmac_secret_once: plaintext} = create!(schema_name)

      {:ok, [listed]} = Webhooks.list(prefix: schema_name)

      assert listed.id == subscription.id
      refute Map.has_key?(Map.from_struct(listed), :hmac_secret_once)
      # secret_hash is not a field on Letflow.Webhooks.Subscription at all as of
      # REQ-190 -- its struct-level absence is itself the assertion (matching the
      # schema's own moduledoc claim), not a value comparison against a field that
      # no longer exists.
      refute Map.has_key?(Map.from_struct(listed), :secret_hash)
      assert listed.secret_ref == subscription.secret_ref
      refute listed.secret_ref == plaintext
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
  # REQ-184 -- list_delivery_attempts/3 (design §1.1)
  # ---------------------------------------------------------------------------------

  describe "REQ-184: list_delivery_attempts/3 orders desc attempted_at, desc attempt_count, and enforces limit" do
    test "returns exactly `limit` rows, most-recent (and highest attempt_count on tie) first" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant("req184-order")
      %{subscription: subscription} = create!(schema_name)

      base_time = DateTime.utc_now() |> DateTime.truncate(:second)

      # Two attempts share the same attempted_at second (tie broken by
      # attempt_count desc); a third and fourth are strictly older.
      d1 =
        insert_delivery!(schema_name, tenant_id, subscription.id, %{
          attempted_at: base_time,
          attempt_count: 1
        })

      d2 =
        insert_delivery!(schema_name, tenant_id, subscription.id, %{
          attempted_at: base_time,
          attempt_count: 2
        })

      _d3 =
        insert_delivery!(schema_name, tenant_id, subscription.id, %{
          attempted_at: DateTime.add(base_time, -60, :second),
          attempt_count: 1
        })

      _d4 =
        insert_delivery!(schema_name, tenant_id, subscription.id, %{
          attempted_at: DateTime.add(base_time, -120, :second),
          attempt_count: 1
        })

      assert {:ok, [first, second]} =
               Webhooks.list_delivery_attempts(subscription.id, 2, prefix: schema_name)

      # d2 (attempt_count 2) sorts before d1 (attempt_count 1) since both
      # share the same attempted_at second -- the limit-2 cutoff excludes
      # the two strictly-older rows.
      assert first.id == d2.id
      assert second.id == d1.id
    end

    test "a real, in-tenant subscription with zero delivery attempts returns {:ok, []}, not an error" do
      %{schema_name: schema_name} = provisioned_tenant("req184-empty")
      %{subscription: subscription} = create!(schema_name)

      assert {:ok, []} = Webhooks.list_delivery_attempts(subscription.id, 20, prefix: schema_name)
    end

    test "a non-existent subscription id returns {:error, :not_found}" do
      %{schema_name: schema_name} = provisioned_tenant("req184-missing")

      assert {:error, :not_found} =
               Webhooks.list_delivery_attempts(Ecto.UUID.generate(), 20, prefix: schema_name)
    end

    test "a malformed subscription id returns {:error, :invalid_id}, no DB round-trip" do
      %{schema_name: schema_name} = provisioned_tenant("req184-invalid")

      assert {:error, :invalid_id} =
               Webhooks.list_delivery_attempts("not-a-uuid", 20, prefix: schema_name)
    end

    test "a real subscription id belonging to another tenant returns {:error, :not_found}, regardless of that tenant's delivery attempts" do
      %{schema_name: schema_a, tenant_id: tenant_id_a} = provisioned_tenant("req184-cross-a")
      %{schema_name: schema_b} = provisioned_tenant("req184-cross-b")

      %{subscription: subscription_a} = create!(schema_a)
      insert_delivery!(schema_a, tenant_id_a, subscription_a.id)

      assert {:error, :not_found} =
               Webhooks.list_delivery_attempts(subscription_a.id, 20, prefix: schema_b)
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

  # ---------------------------------------------------------------------------------
  # REQ-204 — SSRF validation for create/2, deliver/3, and dispatch_http/3
  # ---------------------------------------------------------------------------------

  describe "REQ-204 AC1: create/2 rejects non-https scheme before any DB access" do
    # Scheme check happens first in create/2's with-chain; the DB is never touched.
    # A fake prefix is sufficient because TenantProvisioning.tenant_id_for_schema_name/1
    # is never reached when URL validation short-circuits.
    test "http:// scheme rejected with {:error, :target_url_not_allowed}" do
      assert {:error, :target_url_not_allowed} =
               Webhooks.create(%{target_url: "http://example.com/hook"}, prefix: "not_a_schema")
    end
  end

  describe "REQ-204 AC2: create/2 rejects five explicit private IP literals" do
    # IP literals are checked without a DNS lookup; DB is never touched on rejection.

    test "127.0.0.1 (loopback) rejected" do
      assert {:error, :target_url_not_allowed} =
               Webhooks.create(%{target_url: "https://127.0.0.1/hook"}, prefix: "not_a_schema")
    end

    test "169.254.169.254 (cloud metadata / link-local) rejected" do
      assert {:error, :target_url_not_allowed} =
               Webhooks.create(
                 %{target_url: "https://169.254.169.254/hook"},
                 prefix: "not_a_schema"
               )
    end

    test "10.0.0.5 (RFC-1918) rejected" do
      assert {:error, :target_url_not_allowed} =
               Webhooks.create(%{target_url: "https://10.0.0.5/hook"}, prefix: "not_a_schema")
    end

    test "172.16.0.5 (RFC-1918) rejected" do
      assert {:error, :target_url_not_allowed} =
               Webhooks.create(%{target_url: "https://172.16.0.5/hook"}, prefix: "not_a_schema")
    end

    test "192.168.0.5 (RFC-1918) rejected" do
      assert {:error, :target_url_not_allowed} =
               Webhooks.create(%{target_url: "https://192.168.0.5/hook"}, prefix: "not_a_schema")
    end
  end

  describe "REQ-204 AC3: create/2 succeeds for legitimate https target with public IP literal" do
    test "https target with public IP literal creates the subscription and returns hmac_secret_once" do
      %{schema_name: schema_name} = provisioned_tenant("req204-ac3")

      assert {:ok, %{subscription: subscription, hmac_secret_once: secret}} =
               Webhooks.create(
                 %{target_url: "https://93.184.216.34/hook"},
                 prefix: schema_name
               )

      assert is_binary(secret) and secret != ""
      assert subscription.target_url == "https://93.184.216.34/hook"
      assert subscription.status == :ACTIVE
    end
  end

  describe "REQ-204 AC4: deliver/3 blocks delivery when target_url is a private IP at dispatch time (DNS rebinding)" do
    # Tests defence-in-depth: dispatch_http/3 re-validates target_url immediately
    # before every :httpc.request/4 call, catching DNS rebinding (a URL that was
    # valid at create/2 time can resolve to a private IP at deliver/3 time).
    #
    # Approach: create a subscription with a valid public IP literal (passes
    # create/2), then update target_url directly in the DB to a private IP
    # (simulating the rebinding), then call deliver/3 and assert every attempt
    # is FAILED with the SSRF refusal message.
    #
    # This test is slow (~7s) due to deliver/3's real Process.sleep/1 backoff
    # across four attempts — same class as REQ-183's backoff test. See
    # test/specs/REQ-183.md's "Backoff-timing problem" section.
    @tag timeout: 30_000
    test "deliver/3 records FAILED attempts and does not POST when target_url is private at dispatch time" do
      import Ecto.Query

      %{schema_name: schema_name} = provisioned_tenant("req204-ac4")

      # Create with a valid public IP so create/2 validation passes.
      {:ok, %{subscription: subscription}} =
        Webhooks.create(%{target_url: "https://93.184.216.34/hook"}, prefix: schema_name)

      # Simulate DNS rebinding: update target_url to the cloud metadata IP directly
      # in the DB, bypassing create/2's validator. This models the real attack vector
      # where the hostname resolved to a public IP at subscription time but to
      # 169.254.169.254 at delivery time.
      {1, _} =
        Repo.update_all(
          from(s in Subscription, where: s.id == ^subscription.id),
          [set: [target_url: "https://169.254.169.254/hook"]],
          prefix: schema_name
        )

      reloaded = Repo.get!(Subscription, subscription.id, prefix: schema_name)

      # deliver/3 re-validates at dispatch_http/3 time on every attempt.
      {:ok, last_delivery} =
        Webhooks.deliver(reloaded, "req204.ssrf.dns_rebinding", %{"probe" => true})

      assert last_delivery.status == :FAILED
      assert last_delivery.last_error == "target_url not allowed (SSRF protection)"
      assert is_nil(last_delivery.http_status_code)

      # At least the first attempt must be persisted with the SSRF refusal.
      first_attempt =
        Delivery
        |> where([d], d.delivery_id == ^last_delivery.delivery_id and d.attempt_count == 1)
        |> Repo.one!(prefix: schema_name)

      assert first_attempt.status == :FAILED
      assert first_attempt.last_error == "target_url not allowed (SSRF protection)"
    end
  end

  describe "REQ-204 AC5: dispatch_http/3 does not auto-follow 3xx redirects" do
    # Source-assertion pattern (docs/anti-patterns.md): reading the source file
    # is the robust way to assert a status-quo configuration — no network
    # needed, no timing dependence, and it fails immediately if someone adds
    # the option rather than silently passing through a redirect.
    test "dispatch_http/3 does not pass autoredirect: true or follow_redirect: true to :httpc" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/webhooks.ex"))
      refute source =~ ~r/autoredirect.*true/i
      refute source =~ ~r/follow_redirect.*true/i
    end
  end
end
