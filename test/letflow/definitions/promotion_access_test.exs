defmodule Letflow.Definitions.PromotionAccessTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 12 and section 9 (spec `test/specs/ISS-0993-A1.md`):
  `Letflow.Definitions.PromotionAccess.checker_for/1` -- the real `permission_checker` closure,
  invoked as `checker.(actor_id, source_tenant_id)`. It ignores the FIRST argument and compares
  the SECOND with the caller's tenant id; platform scope is recomputed when the closure is built.

  Pure (no database). `async: false` because the platform pin and the OQ-2 switch are VM-global
  application config. INV-10 check, enforced from the merge of Q-960 PR A; in A1 the checker is
  not wired into any call site.
  """

  use ExUnit.Case, async: false

  alias Letflow.Definitions.PromotionAccess
  alias Letflow.Support.PlatformTenantFixture

  @platform_id Ecto.UUID.generate()
  @own_id Ecto.UUID.generate()
  @other_id Ecto.UUID.generate()

  defp ctx(tenant_id, roles),
    do: %{user_id: Ecto.UUID.generate(), tenant_id: tenant_id, roles: roles}

  setup do
    PlatformTenantFixture.pin!(@platform_id)
    :ok
  end

  describe "ordinary caller" do
    test "own source tenant is true, any letter case, whatever the actor argument" do
      checker = PromotionAccess.checker_for(ctx(@own_id, ["PLATFORM_ADMIN"]))

      assert checker.(Ecto.UUID.generate(), @own_id)
      assert checker.(Ecto.UUID.generate(), String.upcase(@own_id))
      assert checker.(nil, @own_id)
      assert checker.(@other_id, @own_id)
    end

    test "a foreign, nonexistent or malformed source tenant is false" do
      checker = PromotionAccess.checker_for(ctx(@own_id, ["PLATFORM_ADMIN"]))

      for source <- [@other_id, @platform_id, Ecto.UUID.generate(), "slug", "", nil, 5, :atom] do
        refute checker.(Ecto.UUID.generate(), source), "source: #{inspect(source)}"
      end
    end

    test "it is the SECOND argument that is compared: the own id as the actor does not help" do
      checker = PromotionAccess.checker_for(ctx(@own_id, ["PLATFORM_ADMIN"]))

      refute checker.(@own_id, @other_id)
      assert checker.(@other_id, @own_id)
    end

    test "a non-admin role is judged by the same tenant comparison (the checker is not a role check)" do
      checker = PromotionAccess.checker_for(ctx(@own_id, ["PROCESS_DESIGNER"]))

      assert checker.(Ecto.UUID.generate(), @own_id)
      refute checker.(Ecto.UUID.generate(), @other_id)
    end

    test "with the pin unset, an administrator of the would-be platform tenant is an ordinary caller" do
      PlatformTenantFixture.unpin!()
      checker = PromotionAccess.checker_for(ctx(@platform_id, ["PLATFORM_ADMIN"]))

      refute checker.(Ecto.UUID.generate(), @other_id)
      assert checker.(Ecto.UUID.generate(), @platform_id)
    end
  end

  describe "platform operator" do
    test "a PLATFORM_ADMIN of the platform tenant is true for any source" do
      checker = PromotionAccess.checker_for(ctx(@platform_id, ["PLATFORM_ADMIN"]))

      for source <- [@other_id, @own_id, @platform_id, Ecto.UUID.generate(), "slug", nil] do
        assert checker.(Ecto.UUID.generate(), source), "source: #{inspect(source)}"
      end
    end

    test "a non-admin role of the platform tenant gets only its own tenant" do
      checker = PromotionAccess.checker_for(ctx(@platform_id, ["PROCESS_DESIGNER"]))

      assert checker.(Ecto.UUID.generate(), @platform_id)
      refute checker.(Ecto.UUID.generate(), @other_id)
    end

    test "platform scope is fixed when the closure is built, from the context at that time" do
      PlatformTenantFixture.unpin!()
      closed = PromotionAccess.checker_for(ctx(@platform_id, ["PLATFORM_ADMIN"]))
      PlatformTenantFixture.pin!(@platform_id)
      open = PromotionAccess.checker_for(ctx(@platform_id, ["PLATFORM_ADMIN"]))

      refute closed.(nil, @other_id)
      assert open.(nil, @other_id)
    end
  end

  describe "fail closed on odd contexts" do
    test "a missing, empty or non-map auth_context never raises and grants nothing foreign" do
      for auth_context <- [nil, %{}, "str", [], %{roles: ["PLATFORM_ADMIN"]}] do
        checker = PromotionAccess.checker_for(auth_context)

        refute checker.(Ecto.UUID.generate(), @other_id), "context: #{inspect(auth_context)}"
        refute checker.(Ecto.UUID.generate(), nil)
      end
    end

    test "stored scope-fact keys are never read (forged true, missing)" do
      forged =
        PromotionAccess.checker_for(%{
          tenant_id: @own_id,
          roles: ["PLATFORM_ADMIN"],
          platform_scope?: true,
          platform_tenant?: true
        })

      refute forged.(nil, @other_id)
      assert forged.(nil, @own_id)

      stale =
        PromotionAccess.checker_for(%{
          tenant_id: @platform_id,
          roles: ["PLATFORM_ADMIN"],
          platform_scope?: false
        })

      assert stale.(nil, @other_id)
    end
  end

  describe "decision point OQ-2 switch" do
    test "turning cross_tenant_promotion_operator_only? off restores the legacy allow-all pairing" do
      original = Application.fetch_env(:letflow, :cross_tenant_promotion_operator_only)

      on_exit(fn ->
        case original do
          {:ok, value} ->
            Application.put_env(:letflow, :cross_tenant_promotion_operator_only, value)

          :error ->
            Application.delete_env(:letflow, :cross_tenant_promotion_operator_only)
        end
      end)

      Application.put_env(:letflow, :cross_tenant_promotion_operator_only, false)
      assert PromotionAccess.checker_for(ctx(@own_id, ["PLATFORM_ADMIN"])).(nil, @other_id)

      Application.put_env(:letflow, :cross_tenant_promotion_operator_only, true)
      refute PromotionAccess.checker_for(ctx(@own_id, ["PLATFORM_ADMIN"])).(nil, @other_id)
    end
  end
end
