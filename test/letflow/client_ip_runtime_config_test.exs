defmodule Letflow.ClientIpRuntimeConfigTest do
  @moduledoc """
  REQ-439 AC5/AC6 -- `LETFLOW_TRUSTED_PROXIES` and `LETFLOW_LOGIN_DISCOVERY_ENABLED`
  parsing, defaults, and the `:prod` boot refusal in `config/runtime.exs`. Design:
  `lib/letflow/design/req439-trusted-proxy-client-ip.md` s4-s5; spec:
  `test/specs/REQ-439.md`.

  Modelled on `test/letflow/secrets_runtime_config_test.exs`: `config/runtime.exs`
  is evaluated once per BEAM boot, so each case spawns a fresh
  `mix run --no-start -e ...` child process (no Repo, no database) and inspects its
  exit status and output. Every case passes `MIX_TEST_PARTITION`/`MIX_BUILD_PATH`
  as nil (`System.cmd/3` merges `env:` onto the inherited environment, and
  `config/dev.exs` refuses a set `MIX_TEST_PARTITION`) and supplies the committed,
  non-secret test master key because `MIX_ENV=dev`/`prod` has no fallback.

  The `MIX_ENV=prod` cases additionally carry `@tag :prod_build` (they need a
  prod-compiled build, slow and possibly absent in a lean CI). The same decision
  table is covered in-process, without any subprocess, by the `boot_check/3` and
  `parse_enabled/2` tests in `test/letflow/plugs/client_ip_test.exs`.

  Sentinel values used for "must not be echoed" assertions are deliberately
  distinctive and are not secrets.
  """

  use ExUnit.Case, async: true

  @moduletag :slow

  @master_key "3f1c9a2e7b4d6081f5a3c8e2b7d4f6091a3c5e7b9d2f4a6c8e1b3d5f7a9c2e4b"
  @probe ~S|IO.puts("RESULT " <> inspect({Application.get_env(:letflow, Letflow.Plugs.ClientIp), Application.get_env(:letflow, Letflow.Routers.LoginDiscovery)}))|

  @trust_warning "LETFLOW_LOGIN_DISCOVERY_ENABLED is true with LETFLOW_TRUSTED_PROXIES empty"
  @zero_warning "LETFLOW_TRUSTED_PROXIES contains a /0 CIDR"

  # mix_env: "test" | "dev" | "prod"; proxies/enabled: a string or nil (unset).
  defp boot(mix_env, proxies, enabled) do
    env = [
      {"MIX_ENV", mix_env},
      {"MIX_TEST_PARTITION", nil},
      {"MIX_BUILD_PATH", nil},
      {"LETFLOW_SECRETS_MASTER_KEY", @master_key},
      {"LETFLOW_TRUSTED_PROXIES", proxies},
      {"LETFLOW_LOGIN_DISCOVERY_ENABLED", enabled},
      {"DATABASE_URL", "ecto://dummy:dummy@localhost/dummy"}
    ]

    System.cmd("mix", ["run", "--no-start", "-e", @probe],
      env: env,
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end

  defp count(output, needle), do: length(String.split(output, needle)) - 1

  defp assert_boots(output, status) do
    assert status == 0, "expected exit 0, got #{status} with output:\n#{output}"
  end

  defp assert_refused(output, status) do
    refute status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    refute output =~ "RESULT"
  end

  # --- MIX_ENV=test ---------------------------------------------------------

  describe "LETFLOW_TRUSTED_PROXIES (MIX_ENV=test)" do
    test "unset gives [] (and the default enabled true)" do
      {output, status} = boot("test", nil, nil)
      assert_boots(output, status)
      assert output =~ "RESULT {[trusted_proxies: []], [enabled: true]}"
    end

    test "a valid list parses to cidr tuples, order preserved" do
      {output, status} = boot("test", "10.0.0.0/8, 2001:db8::/32,192.168.1.1", nil)
      assert_boots(output, status)

      assert output =~
               "trusted_proxies: [{{10, 0, 0, 0}, 8}, {{8193, 3512, 0, 0, 0, 0, 0, 0}, 32}, {{192, 168, 1, 1}, 32}]"

      refute output =~ @trust_warning
    end

    test "an invalid entry raises at boot with a fixed message and does not echo the value" do
      sentinel = "zz-secret-cidr-91731"
      {output, status} = boot("test", "10.0.0.0/8," <> sentinel, "true")
      assert_refused(output, status)
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      assert output =~ "invalid CIDR entry"
      refute output =~ sentinel
      refute output =~ "10.0.0.0/8"
    end

    test "an out-of-range prefix is invalid and the value is not echoed" do
      {output, status} = boot("test", "10.77.88.99/33", nil)
      assert_refused(output, status)
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      refute output =~ "10.77.88.99"
    end

    test "a /0 entry boots with the fixed warning exactly once and no value" do
      {output, status} = boot("test", "10.0.0.0/8,0.0.0.0/0", "true")
      assert_boots(output, status)
      assert count(output, @zero_warning) == 1
      refute output =~ @trust_warning
    end

    test "a mapped ::ffff:0:0/96 entry (normalised to 0.0.0.0/0) also warns" do
      {output, status} = boot("test", "::ffff:0:0/96", "true")
      assert_boots(output, status)
      assert count(output, @zero_warning) == 1
    end
  end

  describe "LETFLOW_LOGIN_DISCOVERY_ENABLED (MIX_ENV=test)" do
    test "true is accepted" do
      {output, status} = boot("test", "10.0.0.0/8", "true")
      assert_boots(output, status)
      assert output =~ "[enabled: true]"
    end

    test "false is accepted" do
      {output, status} = boot("test", nil, "false")
      assert_boots(output, status)
      assert output =~ "[enabled: false]"
      refute output =~ @trust_warning
    end

    for bad <- ["yes", "TRUE", "1"] do
      test "#{inspect(bad)} raises with a fixed message and does not echo the value" do
        bad = unquote(bad)
        {output, status} = boot("test", nil, bad)
        assert_refused(output, status)
        assert output =~ "LETFLOW_LOGIN_DISCOVERY_ENABLED"
        assert output =~ "must be exactly true or false"
        refute output =~ "\"#{bad}\""
        refute output =~ "=#{bad}"
      end
    end

    test "a sentinel invalid value is not echoed" do
      sentinel = "zz-secret-flag-55120"
      {output, status} = boot("test", nil, sentinel)
      assert_refused(output, status)
      assert output =~ "LETFLOW_LOGIN_DISCOVERY_ENABLED"
      refute output =~ sentinel
    end
  end

  # --- MIX_ENV=dev ----------------------------------------------------------

  describe "MIX_ENV=dev" do
    test "defaults to enabled true; the empty list only prints the fixed warning, once" do
      {output, status} = boot("dev", nil, nil)
      assert_boots(output, status)
      assert output =~ "RESULT {[trusted_proxies: []], [enabled: true]}"
      assert count(output, @trust_warning) == 1
    end

    test "explicitly enabled with an empty list also boots with the warning" do
      {output, status} = boot("dev", "", "true")
      assert_boots(output, status)
      assert count(output, @trust_warning) == 1
    end

    test "disabled prints no warning" do
      {output, status} = boot("dev", nil, "false")
      assert_boots(output, status)
      assert output =~ "[enabled: false]"
      refute output =~ @trust_warning
    end

    test "enabled with a non-empty list prints no warning" do
      {output, status} = boot("dev", "172.16.0.0/12", "true")
      assert_boots(output, status)
      refute output =~ @trust_warning
    end
  end

  # --- MIX_ENV=prod ---------------------------------------------------------

  describe "MIX_ENV=prod boot refusal" do
    @describetag :prod_build

    test "default enabled is false and the node boots with no trust list" do
      {output, status} = boot("prod", nil, nil)
      assert_boots(output, status)
      assert output =~ "RESULT {[trusted_proxies: []], [enabled: false]}"
    end

    test "enabled with an unset trust list is refused, naming both variables, no value" do
      {output, status} = boot("prod", nil, "true")
      assert_refused(output, status)
      assert output =~ "LETFLOW_LOGIN_DISCOVERY_ENABLED"
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      assert output =~ "refusing to boot"
    end

    test "enabled with a blank trust list is refused" do
      {output, status} = boot("prod", "  , ", "true")
      assert_refused(output, status)
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      assert output =~ "refusing to boot"
    end

    test "enabled with a non-empty list boots" do
      {output, status} = boot("prod", "172.18.0.1", "true")
      assert_boots(output, status)
      assert output =~ "RESULT {[trusted_proxies: [{{172, 18, 0, 1}, 32}]], [enabled: true]}"
      refute output =~ @trust_warning
    end

    test "disabled with an empty list boots" do
      {output, status} = boot("prod", nil, "false")
      assert_boots(output, status)
      assert output =~ "[enabled: false]"
    end

    test "the refusal fires before the DATABASE_URL raise and carries no env value" do
      sentinel = "ecto://dummy:dummy@localhost/dummy"
      {output, status} = boot("prod", nil, "true")
      assert_refused(output, status)
      refute output =~ "DATABASE_URL"
      refute output =~ sentinel
    end

    test "an invalid trust list raises in prod too, without echoing" do
      sentinel = "zz-secret-cidr-70011"
      {output, status} = boot("prod", sentinel, "true")
      assert_refused(output, status)
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      refute output =~ sentinel
    end
  end
end
