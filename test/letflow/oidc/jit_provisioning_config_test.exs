defmodule Letflow.Oidc.JitProvisioningConfigTest do
  @moduledoc """
  Unit tests for `Letflow.Oidc.JitProvisioningConfig`. See `test/specs/REQ-018.md`
  for the full test-case rationale.

  Plain `ExUnit.Case, async: true` — no `Letflow.DataCase`, no
  `Ecto.Adapters.SQL.Sandbox`. `for_realm/1` only performs a config read
  (`Application.fetch_env!/2`), not DB/network I/O; `default/1` and
  `default_roles/1` are pure struct logic. No `Letflow.Repo` connection is needed
  for any test in this file to pass.
  """

  use ExUnit.Case, async: true

  alias Letflow.Oidc.JitProvisioningConfig

  describe "for_realm/1 / default/1" do
    test "for_realm/1 returns the configured entry for a realm present in application config" do
      config = JitProvisioningConfig.for_realm("bpm-default")

      assert config.realm == "bpm-default"
      assert config.enabled == true
      assert config.default_status == :active
      assert config.default_roles == []
    end

    test "for_realm/1 falls back to default/1 for a realm with no config entry" do
      assert JitProvisioningConfig.for_realm("unconfigured-realm") ==
               JitProvisioningConfig.default("unconfigured-realm")
    end

    test "default/1 threads the given realm into the returned struct's realm field, not Zig's literal empty string" do
      assert JitProvisioningConfig.default("some-realm").realm == "some-realm"
      assert JitProvisioningConfig.default("other-realm").realm == "other-realm"
    end

    test "default/1 mirrors DEFAULT_JIT_CONFIG: enabled true, default_status :active, default_roles []" do
      config = JitProvisioningConfig.default("any-realm")

      assert config.enabled == true
      assert config.default_status == :active
      assert config.default_roles == []
    end
  end

  describe "default_roles/1" do
    test "empty default_roles falls back to [\"VIEWER\"]" do
      config = JitProvisioningConfig.default("some-realm")
      assert config.default_roles == []

      assert JitProvisioningConfig.default_roles(config) == ["VIEWER"]
    end

    test "non-empty default_roles is returned unchanged" do
      config = %JitProvisioningConfig{
        realm: "some-realm",
        enabled: true,
        default_status: :active,
        default_roles: ["APPROVER", "REVIEWER"]
      }

      assert JitProvisioningConfig.default_roles(config) == ["APPROVER", "REVIEWER"]
    end
  end
end
