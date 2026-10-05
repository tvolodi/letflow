defmodule Letflow.PlatformTenantTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 1 (spec `test/specs/ISS-0993-A1.md`):
  unit tests of `Letflow.PlatformTenant` -- the configuration-pinned platform tenant.

  INV-10 check ("platform authority bound to the platform tenant"), enforced from the merge of
  Q-960 PR A.

  `async: false`: the pin is VM-global application config (`Letflow.Support.PlatformTenantFixture`
  restores it after every test). No database is touched.
  """

  use ExUnit.Case, async: false

  alias Letflow.PlatformTenant
  alias Letflow.Support.PlatformTenantFixture

  @upper "1A2B3C4D-0000-4000-8000-ABCDEF012345"
  @lower String.downcase(@upper)

  describe "parse_env/1" do
    test "nil, empty and whitespace-only input are unset" do
      for raw <- [nil, "", "   ", "\t", "\n", " \t\n "] do
        assert PlatformTenant.parse_env(raw) == {:ok, nil}, "input: #{inspect(raw)}"
      end
    end

    test "a hyphenated UUID is returned canonical lower-case, whatever the input case" do
      assert PlatformTenant.parse_env(@upper) == {:ok, @lower}
      assert PlatformTenant.parse_env(@lower) == {:ok, @lower}
      assert PlatformTenant.parse_env("  " <> @upper <> "  ") == {:ok, @lower}
    end

    test "anything that is not a canonical hyphenated UUID is rejected" do
      uuid = Ecto.UUID.generate()

      for raw <- [
            "garbage",
            "{" <> uuid <> "}",
            String.replace(uuid, "-", ""),
            uuid <> "x",
            "x" <> uuid,
            String.slice(uuid, 0, 35),
            "urn:uuid:" <> uuid,
            "bpm-default",
            uuid <> "\n" <> uuid,
            # "g" is not a hex digit
            "g" <> String.slice(uuid, 1, 40)
          ] do
        assert PlatformTenant.parse_env(raw) == {:error, :invalid_uuid}, "input: #{inspect(raw)}"
      end
    end

    test "a non-binary, non-nil input is rejected without raising" do
      for raw <- [123, :atom, [], %{}, {:a, :b}] do
        assert PlatformTenant.parse_env(raw) == {:error, :invalid_uuid}
      end
    end
  end

  describe "uuid?/1" do
    test "true only for a canonical hyphenated UUID string, any case" do
      assert PlatformTenant.uuid?(Ecto.UUID.generate())
      assert PlatformTenant.uuid?(@upper)
      assert PlatformTenant.uuid?(@lower)
    end

    test "false for every other term" do
      uuid = Ecto.UUID.generate()

      for value <- [
            nil,
            "",
            "slug-like",
            String.replace(uuid, "-", ""),
            uuid <> "\n",
            " " <> uuid,
            :atom,
            123,
            %{},
            String.duplicate("a", 5000)
          ] do
        refute PlatformTenant.uuid?(value), "value: #{inspect(value)}"
      end
    end
  end

  describe "configured_id/0 and platform_tenant?/1" do
    test "with the pin unset every input, nil included, is not the platform tenant" do
      PlatformTenantFixture.unpin!()

      assert PlatformTenant.configured_id() == nil

      for id <- [nil, "", @upper, @lower, Ecto.UUID.generate(), :atom, 7] do
        refute PlatformTenant.platform_tenant?(id), "input: #{inspect(id)}"
      end
    end

    test "a malformed or non-binary configured value reads as unset (fail closed)" do
      for bad <- [nil, 123, :oops] do
        PlatformTenantFixture.pin!(bad)

        assert PlatformTenant.configured_id() == nil
        refute PlatformTenant.platform_tenant?(@lower)
        refute PlatformTenant.platform_tenant?(Ecto.UUID.generate())
        refute PlatformTenant.platform_tenant?(nil)
      end
    end

    test "with a pin set, equality is case-insensitive in both directions" do
      PlatformTenantFixture.pin!(@lower)

      assert PlatformTenant.configured_id() == @lower
      assert PlatformTenant.platform_tenant?(@lower)
      assert PlatformTenant.platform_tenant?(@upper)

      PlatformTenantFixture.pin!(@upper)

      # a pin configured upper-case is still read canonical lower-case
      assert PlatformTenant.configured_id() == @lower
      assert PlatformTenant.platform_tenant?(@lower)
    end

    test "with a pin set, any other id, nil and non-binaries are not the platform tenant" do
      PlatformTenantFixture.pin!(@lower)

      refute PlatformTenant.platform_tenant?(Ecto.UUID.generate())
      refute PlatformTenant.platform_tenant?(nil)
      refute PlatformTenant.platform_tenant?("")
      refute PlatformTenant.platform_tenant?(@lower <> " ")
      refute PlatformTenant.platform_tenant?(:atom)
      refute PlatformTenant.platform_tenant?(42)
    end

    test "with_platform_tenant!/2 restores the previous config, also when the function raises" do
      PlatformTenantFixture.pin!(@lower)

      assert PlatformTenantFixture.with_platform_tenant!(@upper, fn ->
               PlatformTenant.configured_id()
             end) == @lower

      assert PlatformTenantFixture.with_platform_tenant!(nil, fn ->
               PlatformTenant.platform_tenant?(@lower)
             end) == false

      assert_raise RuntimeError, "boom", fn ->
        PlatformTenantFixture.with_platform_tenant!(nil, fn -> raise "boom" end)
      end

      assert PlatformTenant.configured_id() == @lower
    end
  end

  describe "scope_facts/2" do
    test "platform tenant without the role: tenant fact true, scope fact false" do
      PlatformTenantFixture.pin!(@lower)

      assert PlatformTenant.scope_facts(@lower, ["PROCESS_DESIGNER"]) ==
               %{platform_tenant?: true, platform_scope?: false}

      assert PlatformTenant.scope_facts(@lower, []) ==
               %{platform_tenant?: true, platform_scope?: false}
    end

    test "platform tenant with PLATFORM_ADMIN: both true (also with other roles, upper-case id)" do
      PlatformTenantFixture.pin!(@lower)

      assert PlatformTenant.scope_facts(@upper, ["PLATFORM_ADMIN"]) ==
               %{platform_tenant?: true, platform_scope?: true}

      assert PlatformTenant.scope_facts(@lower, ["PROCESS_DESIGNER", "PLATFORM_ADMIN"]) ==
               %{platform_tenant?: true, platform_scope?: true}
    end

    test "another tenant's PLATFORM_ADMIN has neither fact" do
      PlatformTenantFixture.pin!(@lower)

      assert PlatformTenant.scope_facts(Ecto.UUID.generate(), ["PLATFORM_ADMIN"]) ==
               %{platform_tenant?: false, platform_scope?: false}
    end

    test "pin unset: PLATFORM_ADMIN of any tenant has neither fact" do
      PlatformTenantFixture.unpin!()

      assert PlatformTenant.scope_facts(@lower, ["PLATFORM_ADMIN"]) ==
               %{platform_tenant?: false, platform_scope?: false}

      assert PlatformTenant.scope_facts(nil, ["PLATFORM_ADMIN"]) ==
               %{platform_tenant?: false, platform_scope?: false}
    end

    test "an unrecognised role string confers nothing; odd role input never raises" do
      PlatformTenantFixture.pin!(@lower)

      for roles <- [["platform_admin"], [" PLATFORM_ADMIN"], ["PLATFORM_ADMIN "], nil, :x] do
        assert %{platform_scope?: false} = PlatformTenant.scope_facts(@lower, roles),
               "roles: #{inspect(roles)}"
      end
    end
  end

  describe "scope_facts_for/1" do
    test "reads tenant_id and roles from an auth_context-shaped map" do
      PlatformTenantFixture.pin!(@lower)

      assert PlatformTenant.scope_facts_for(%{tenant_id: @lower, roles: ["PLATFORM_ADMIN"]}) ==
               %{platform_tenant?: true, platform_scope?: true}
    end

    test "a hand-assigned map without the stored fact keys, roles or tenant_id does not raise and is fail-closed" do
      PlatformTenantFixture.pin!(@lower)
      closed = %{platform_tenant?: false, platform_scope?: false}

      assert PlatformTenant.scope_facts_for(%{}) == closed
      assert PlatformTenant.scope_facts_for(%{roles: ["PLATFORM_ADMIN"]}) == closed

      assert PlatformTenant.scope_facts_for(%{tenant_id: @lower}) ==
               %{platform_tenant?: true, platform_scope?: false}
    end

    test "a stored fact is never read, in either direction" do
      PlatformTenantFixture.pin!(@lower)

      forged = %{
        tenant_id: Ecto.UUID.generate(),
        roles: ["PLATFORM_ADMIN"],
        platform_tenant?: true,
        platform_scope?: true
      }

      assert PlatformTenant.scope_facts_for(forged) ==
               %{platform_tenant?: false, platform_scope?: false}

      stale = %{tenant_id: @lower, roles: ["PLATFORM_ADMIN"], platform_scope?: false}

      assert PlatformTenant.scope_facts_for(stale) ==
               %{platform_tenant?: true, platform_scope?: true}
    end

    test "a non-map input gives both facts false" do
      PlatformTenantFixture.pin!(@lower)

      for input <- [nil, "str", 12, :atom, [tenant_id: @lower, roles: ["PLATFORM_ADMIN"]]] do
        assert PlatformTenant.scope_facts_for(input) ==
                 %{platform_tenant?: false, platform_scope?: false},
               "input: #{inspect(input)}"
      end
    end
  end

  describe "read functions only" do
    test "no exported function is named like a configuration writer" do
      names = PlatformTenant.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

      for name <- names do
        refute Atom.to_string(name) =~ ~r/^(put|set|write|update|pin)/,
               "unexpected writer-looking function #{name}"
      end
    end
  end
end
