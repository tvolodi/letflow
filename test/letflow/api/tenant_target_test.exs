defmodule Letflow.Api.TenantTargetTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 11 and section 8 (spec `test/specs/ISS-0993-A1.md`):
  the pure contract of `Letflow.Api.TenantTarget.authorize_target_tenant/2` --

    (a) platform operator -> `:ok` for any target;
    (b) the caller's own tenant id (case-insensitive, canonical UUID) -> `:ok`;
    (c) another tenant, a nonexistent id, a malformed id, a slug, `nil` -> `{:error, :not_found}`;
    (d) never raises on odd input (missing `auth_context`, missing keys, forged stored flags).

  Runs WITHOUT a database sandbox checkout (plain `ExUnit.Case`): the helper is pure, so any
  `Repo` interaction would raise an ownership error and fail the test. `async: false` because the
  platform pin is VM-global config.

  INV-10 check, enforced from the merge of Q-960 PR A. In A1 no handler calls this helper yet;
  these tests are the whole of its coverage until A2 wires it.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.TenantTarget
  alias Letflow.Support.PlatformTenantFixture

  @platform_id Ecto.UUID.generate()
  @own_id Ecto.UUID.generate()
  @other_id Ecto.UUID.generate()

  defp conn_with(auth_context),
    do: conn(:get, "/") |> assign(:auth_context, auth_context)

  defp ctx(tenant_id, roles),
    do: %{user_id: Ecto.UUID.generate(), tenant_id: tenant_id, roles: roles}

  setup do
    PlatformTenantFixture.pin!(@platform_id)
    :ok
  end

  describe "platform operator (rule 1)" do
    test "a PLATFORM_ADMIN of the platform tenant may name any target" do
      conn = conn_with(ctx(@platform_id, ["PLATFORM_ADMIN"]))

      for target <- [@other_id, @own_id, @platform_id, Ecto.UUID.generate(), "a-slug", "x", nil] do
        assert TenantTarget.authorize_target_tenant(conn, target) == :ok,
               "target: #{inspect(target)}"
      end
    end

    test "the platform tenant id is matched case-insensitively" do
      conn = conn_with(ctx(String.upcase(@platform_id), ["PLATFORM_ADMIN"]))
      assert TenantTarget.authorize_target_tenant(conn, @other_id) == :ok
    end

    test "a non-admin role of the platform tenant has no platform scope" do
      conn = conn_with(ctx(@platform_id, ["PROCESS_DESIGNER"]))

      assert TenantTarget.authorize_target_tenant(conn, @other_id) == {:error, :not_found}
      # ... but its own tenant (rule 2) is still fine
      assert TenantTarget.authorize_target_tenant(conn, @platform_id) == :ok
    end

    test "with the pin unset the platform tenant's PLATFORM_ADMIN is an ordinary caller" do
      PlatformTenantFixture.unpin!()
      conn = conn_with(ctx(@platform_id, ["PLATFORM_ADMIN"]))

      assert TenantTarget.authorize_target_tenant(conn, @other_id) == {:error, :not_found}
      assert TenantTarget.authorize_target_tenant(conn, @platform_id) == :ok
    end
  end

  describe "ordinary caller (rules 2 and 3)" do
    for {label, roles} <- [
          admin: ["TENANT_ADMIN"],
          # REQ-447 PR 2: a non-platform tenant's PLATFORM_ADMIN is a legacy identity that holds
          # nothing; it must stay an ordinary caller (no platform scope) for target purposes.
          legacy_platform_admin: ["PLATFORM_ADMIN"],
          designer: ["PROCESS_DESIGNER"],
          no_roles: []
        ] do
      test "#{label}: own id is accepted, in any letter case" do
        conn = conn_with(ctx(@own_id, unquote(roles)))

        assert TenantTarget.authorize_target_tenant(conn, @own_id) == :ok
        assert TenantTarget.authorize_target_tenant(conn, String.upcase(@own_id)) == :ok
      end

      test "#{label}: an upper-case own id on the context accepts a lower-case target" do
        conn = conn_with(ctx(String.upcase(@own_id), unquote(roles)))
        assert TenantTarget.authorize_target_tenant(conn, String.downcase(@own_id)) == :ok
      end

      test "#{label}: another tenant, a nonexistent id, a malformed id, a slug and nil are all not_found" do
        conn = conn_with(ctx(@own_id, unquote(roles)))

        for target <- [
              @other_id,
              @platform_id,
              Ecto.UUID.generate(),
              "not-a-uuid",
              "bpm-default",
              "",
              " ",
              String.replace(@own_id, "-", ""),
              @own_id <> " ",
              @own_id <> "\n",
              String.duplicate("a", 5000),
              nil
            ] do
          assert TenantTarget.authorize_target_tenant(conn, target) == {:error, :not_found},
                 "target: #{inspect(target)}"
        end
      end
    end

    test "a slug is never accepted without platform scope, even when it equals the caller's own slug-like id text" do
      conn = conn_with(ctx("my-tenant-slug", ["PLATFORM_ADMIN"]))
      assert TenantTarget.authorize_target_tenant(conn, "my-tenant-slug") == {:error, :not_found}
    end
  end

  describe "never raises" do
    test "an auth_context lacking the stored scope-fact keys is fail-closed" do
      conn = conn_with(%{tenant_id: @own_id, roles: ["PLATFORM_ADMIN"]})

      assert TenantTarget.authorize_target_tenant(conn, @other_id) == {:error, :not_found}
      assert TenantTarget.authorize_target_tenant(conn, @own_id) == :ok
    end

    test "a forged platform_scope?: true on a non-platform tenant context does not grant platform scope" do
      conn =
        conn_with(%{
          user_id: "u",
          tenant_id: @own_id,
          roles: ["PLATFORM_ADMIN"],
          platform_scope?: true,
          platform_tenant?: true
        })

      assert TenantTarget.authorize_target_tenant(conn, @other_id) == {:error, :not_found}
    end

    test "a stored platform_scope?: false does not remove a recomputed platform scope" do
      conn =
        conn_with(%{
          tenant_id: @platform_id,
          roles: ["PLATFORM_ADMIN"],
          platform_scope?: false,
          platform_tenant?: false
        })

      assert TenantTarget.authorize_target_tenant(conn, @other_id) == :ok
    end

    test "no auth_context assign at all, an empty context and a context missing tenant_id" do
      assert TenantTarget.authorize_target_tenant(conn(:get, "/"), @other_id) ==
               {:error, :not_found}

      assert TenantTarget.authorize_target_tenant(conn_with(%{}), @other_id) ==
               {:error, :not_found}

      assert TenantTarget.authorize_target_tenant(conn_with(%{roles: ["PLATFORM_ADMIN"]}), nil) ==
               {:error, :not_found}

      assert TenantTarget.authorize_target_tenant(conn_with(%{tenant_id: nil, roles: []}), nil) ==
               {:error, :not_found}
    end

    test "odd tenant_id, roles and target values" do
      for auth_context <- [
            nil,
            "string",
            %{tenant_id: 123, roles: ["PLATFORM_ADMIN"]},
            %{tenant_id: @own_id, roles: nil},
            %{tenant_id: @own_id, roles: :admin},
            %{tenant_id: @own_id, roles: [nil, 1, :x]}
          ],
          target <- [nil, 7, :atom, %{}, [@own_id], @other_id] do
        assert TenantTarget.authorize_target_tenant(conn_with(auth_context), target) ==
                 {:error, :not_found},
               "context: #{inspect(auth_context)} target: #{inspect(target)}"
      end
    end

    test "a non-conn first argument" do
      for first <- [nil, %{}, "conn", %{assigns: %{}}] do
        assert TenantTarget.authorize_target_tenant(first, @own_id) == {:error, :not_found}
      end
    end
  end
end
