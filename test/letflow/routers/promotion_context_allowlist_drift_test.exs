defmodule Letflow.Routers.PromotionContextAllowlistDriftTest do
  @moduledoc """
  ISS-1021 T-12 (design section 6 file 4; ISS-1023 adds the `entries_gate` pin): the `/context` plan allowlist and the keys
  `PromotionPlan.compute_promotion_plan/5` really emits must not drift apart. The expected sets
  are written literally here (not derived from the allowlist): a new or renamed plan key fails
  this test until a person classifies it for a non-operator reader.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.PromotionPlan
  alias Letflow.Routers.Promotions
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  @plain ["base_version", "process_key"]
  @own_tenant ["source_tenant_id", "target_tenant_id"]
  @own_side %{
    "source_definition_id" => "source_tenant_id",
    "target_definition_id" => "target_tenant_id"
  }
  @entries "entries"
  @entries_gate ["source_tenant_id", "target_tenant_id"]

  setup do
    {:ok, Fixture.three_tenants!()}
  end

  test "allowlist_matches_the_literal_table" do
    allowlist = Promotions.plan_allowlist()

    assert Enum.sort(allowlist.plain) == @plain
    assert Enum.sort(allowlist.own_tenant) == @own_tenant
    assert allowlist.own_side == @own_side
    assert allowlist.entries == @entries
    assert Enum.sort(allowlist.entries_gate) == @entries_gate
  end

  # ISS-1023: a new tenant-id key added to `own_tenant` fails this until a person decides
  # whether it must also gate `entries`.
  test "entries_gate_is_the_own_tenant_pair" do
    allowlist = Promotions.plan_allowlist()

    assert Enum.sort(allowlist.entries_gate) == Enum.sort(allowlist.own_tenant)
    assert Enum.all?(allowlist.entries_gate, &(&1 in allowlist.own_tenant))
  end

  test "allowlist_covers_exactly_the_keys_the_plan_builder_emits", ctx do
    key = Scope.unique_key("iss1021-drift")
    Scope.insert_active_definition!(ctx.a, key, "1.0.0")

    assert {:ok, plan} =
             PromotionPlan.compute_promotion_plan(
               Ecto.UUID.generate(),
               ctx.a.tenant_id,
               ctx.b.tenant_id,
               key,
               permission_checker: fn _, _ -> true end,
               tenant_classifier: fn _ -> :test end
             )

    allowlist = Promotions.plan_allowlist()

    allowed =
      Enum.sort(
        allowlist.plain ++
          allowlist.own_tenant ++ Map.keys(allowlist.own_side) ++ [allowlist.entries]
      )

    assert plan |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort() == allowed
  end

  test "own_side_gates_are_emitted_tenant_id_keys" do
    allowlist = Promotions.plan_allowlist()
    for {_def_key, gate} <- allowlist.own_side, do: assert(gate in allowlist.own_tenant)
  end

  test "class_sets_are_disjoint" do
    allowlist = Promotions.plan_allowlist()

    all =
      allowlist.plain ++
        allowlist.own_tenant ++ Map.keys(allowlist.own_side) ++ [allowlist.entries]

    assert length(all) == length(Enum.uniq(all))
  end
end
