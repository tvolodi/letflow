defmodule Letflow.Routers.PromotionPlatformEventsAllowlistDriftTest do
  @moduledoc """
  ISS-0999 T-9 (design section 6 file 5): the platform-events response allowlist and the
  shipped event-type registry schemas must not drift apart. The expected sets are written
  literally here (not derived from the allowlist): a new or renamed registry property fails
  this test until a person decides whether it is kept, kept-if-own-tenant, or omitted for a
  non-operator reader.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EventStore.Registry.EventType
  alias Letflow.EventStore.Registry
  alias Letflow.Routers.Promotions
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @table %{
    "DEFINITION_PROMOTED" => %{
      plain: ["process_key", "target_definition_id"],
      own_tenant: ["source_tenant_id", "target_tenant_id"],
      omitted: ["review_id", "source_definition_id"]
    },
    "DEFINITION_VERSION_ROLLED_BACK" => %{
      plain: ["from_version", "process_key", "to_version"],
      own_tenant: [],
      omitted: []
    },
    "PROMOTION_ASSERTION_TEARDOWN_FAILED" => %{
      plain: ["run_id", "sandbox_id"],
      own_tenant: ["tenant_id"],
      omitted: ["error"]
    }
  }

  setup do
    tenants = Fixture.three_tenants!()
    {:ok, tenant_id: tenants.a.tenant_id}
  end

  test "allowlist_covers_exactly_the_three_event_types" do
    assert Promotions.platform_event_allowlist() |> Map.keys() |> Enum.sort() ==
             Enum.sort(Map.keys(@table))
  end

  test "allowlist_matches_the_literal_table" do
    allowlist = Promotions.platform_event_allowlist()

    for {type, expected} <- @table do
      assert Enum.sort(allowlist[type].plain) == expected.plain, "#{type} plain"
      assert Enum.sort(allowlist[type].own_tenant) == expected.own_tenant, "#{type} own_tenant"
    end
  end

  test "registry_properties_equal_the_union_of_kept_and_omitted_and_sets_are_disjoint", ctx do
    for {type, expected} <- @table do
      assert {:ok, %EventType{json_schema: schema}} = Registry.get_type(type, ctx.tenant_id)
      properties = schema["properties"] |> Map.keys() |> Enum.sort()

      all = expected.plain ++ expected.own_tenant ++ expected.omitted
      assert Enum.sort(all) == properties, "#{type}: registry properties drifted"
      assert length(all) == length(Enum.uniq(all)), "#{type}: table sets overlap"
    end
  end
end
