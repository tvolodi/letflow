defmodule Letflow.PlatformTenantRuntimeConfigTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 3 and section 12 item 2 (spec `test/specs/ISS-0993-A1.md`):
  the optional `LETFLOW_PLATFORM_TENANT_ID` in `config/runtime.exs`, observed by a
  controlled-environment child `mix run --no-start` (config is evaluated, no application or
  database is started) -- the same technique, and for the same reason, as
  `login_discovery_runtime_config_test.exs`: `config/runtime.exs` runs once, at boot, so a
  boot-time `raise` is only observable from a child process.

  `System.cmd/3`'s `env:` MERGES onto this VM's environment, so every variable under test is
  explicitly set or explicitly `nil`-ed in every case (never left to inherit; an empty string is
  indistinguishable from unset on this host, so "blank" is whitespace-only). `MIX_TEST_PARTITION`
  and `MIX_BUILD_PATH` are `nil`-ed (CI exports the partition variable, which would send the child
  to a different build directory).

  Cases (what each asserts):

    * unset or blank, `MIX_ENV=test`: boots, `tenant_id: nil`, no warning (the pin is always unset
      under test and a warning there would be noise);
    * unset, `MIX_ENV=dev`: boots, `tenant_id: nil`, and the FIXED A1 warning text is printed;
    * a valid UUID in any letter case: boots, stored canonical lower-case, no warning;
    * a malformed value: boot stops, the message names the variable and states that the value is
      not echoed, the value itself never appears in the output, the probe is never reached.

  The master key is built at compile time, never a 64-hex literal (the no-secret guard scans
  tracked files); the pepper pair is supplied for `dev` (no fallback there).

  `@moduletag :slow` (run with `--include slow`), `async: false`.
  """

  use ExUnit.Case, async: false

  @moduletag :slow

  @var "LETFLOW_PLATFORM_TENANT_ID"
  @master "LETFLOW_SECRETS_MASTER_KEY"
  @pepper "LETFLOW_LOGIN_DIRECTORY_PEPPER"
  @pepper_id "LETFLOW_LOGIN_DIRECTORY_PEPPER_ID"
  @previous "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS"
  @previous_id "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID"
  @master_key String.duplicate("3f1c9a2e7b4d6081", 4)

  @warning "LETFLOW_PLATFORM_TENANT_ID is unset: platform scope is not enforced yet (shadow mode)."

  @probe ~S|IO.puts("RESULT " <> inspect(Application.get_env(:letflow, Letflow.PlatformTenant)))|

  defp hex32, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  # value: a string or nil (unset). Returns {output, exit_status}.
  defp boot(mix_env, value) do
    env = [
      {"MIX_ENV", mix_env},
      {"MIX_TEST_PARTITION", nil},
      {"MIX_BUILD_PATH", nil},
      {@master, @master_key},
      {@var, value},
      {"LETFLOW_TRUSTED_PROXIES", nil},
      {"DATABASE_URL", "ecto://dummy:dummy@localhost/dummy"}
    ]

    # dev has no pepper fallback (config/test.exs injects one): supply a fresh pair
    env =
      if mix_env == "dev" do
        env ++ [{@pepper, hex32()}, {@pepper_id, "cur-1"}, {@previous, nil}, {@previous_id, nil}]
      else
        env
      end

    System.cmd("mix", ["run", "--no-start", "-e", @probe],
      env: env,
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end

  defp assert_boots(output, status) do
    assert status == 0, "expected exit 0, got #{status} with output:\n#{output}"
  end

  defp assert_refused(output, status, value) do
    refute status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    refute output =~ "RESULT", "boot must not reach the probe:\n#{output}"
    assert output =~ @var, "the message must name #{@var}:\n#{output}"
    assert output =~ "UUID", "the message must state the accepted form:\n#{output}"
    assert output =~ "not echoed", "the message must say the value is not echoed:\n#{output}"
    refute output =~ String.trim(value), "output must not echo the supplied value:\n#{output}"
  end

  describe "unset / blank under MIX_ENV=test" do
    for {label, value} <- [unset: nil, whitespace_only: "   ", tab: "\t"] do
      test "#{label} boots with no pin and no warning" do
        {output, status} = boot("test", unquote(value))
        assert_boots(output, status)
        assert output =~ "RESULT [tenant_id: nil]"
        refute output =~ @warning
      end
    end
  end

  describe "unset under a non-test environment" do
    test "MIX_ENV=dev, unset: boots, no pin, and the fixed A1 warning is printed" do
      {output, status} = boot("dev", nil)
      assert_boots(output, status)
      assert output =~ "RESULT [tenant_id: nil]"
      assert output =~ @warning
    end

    test "MIX_ENV=dev, whitespace-only: same as unset" do
      {output, status} = boot("dev", "   ")
      assert_boots(output, status)
      assert output =~ "RESULT [tenant_id: nil]"
      assert output =~ @warning
    end

    test "MIX_ENV=dev, a valid UUID: boots with the pin set and no warning" do
      uuid = Ecto.UUID.generate()
      {output, status} = boot("dev", uuid)
      assert_boots(output, status)
      assert output =~ ~s|RESULT [tenant_id: "#{uuid}"]|
      refute output =~ @warning
    end

    test "MIX_ENV=dev, a malformed value stops boot without echoing it" do
      value = "leaky-platform-value-7731"
      {output, status} = boot("dev", value)
      assert_refused(output, status, value)
    end
  end

  describe "a valid value sets the pin" do
    test "a lower-case UUID is stored as given" do
      uuid = Ecto.UUID.generate()
      {output, status} = boot("test", uuid)
      assert_boots(output, status)
      assert output =~ ~s|RESULT [tenant_id: "#{uuid}"]|
    end

    test "an upper-case UUID is stored canonical lower-case" do
      uuid = Ecto.UUID.generate()
      {output, status} = boot("test", String.upcase(uuid))
      assert_boots(output, status)
      assert output =~ ~s|RESULT [tenant_id: "#{uuid}"]|
    end

    test "surrounding whitespace is trimmed" do
      uuid = Ecto.UUID.generate()
      {output, status} = boot("test", "  " <> uuid <> "  ")
      assert_boots(output, status)
      assert output =~ ~s|RESULT [tenant_id: "#{uuid}"]|
    end
  end

  describe "a malformed value stops boot without echoing it" do
    for {label, value} <- [
          sentinel: "leaky-platform-value-7731",
          braced: "{4f6c1c7a-1b0e-4c0e-9d3a-5a1b2c3d4e5f}",
          no_hyphens: "4f6c1c7a1b0e4c0e9d3a5a1b2c3d4e5f",
          trailing_garbage: "4f6c1c7a-1b0e-4c0e-9d3a-5a1b2c3d4e5f-extra",
          slug: "bpm-default",
          not_hex: "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"
        ] do
      test "#{label}" do
        {output, status} = boot("test", unquote(value))
        assert_refused(output, status, unquote(value))
      end
    end
  end
end
