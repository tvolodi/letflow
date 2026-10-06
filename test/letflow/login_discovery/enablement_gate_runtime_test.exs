defmodule Letflow.LoginDiscovery.EnablementGateRuntimeTest do
  @moduledoc """
  REQ-444 criterion 2 (spec `test/specs/REQ-444.md`): the boot refusal observed through
  `config/runtime.exs` evaluated in a controlled-environment child (`mix run --no-start`,
  no application, no database) -- the technique of `client_ip_runtime_config_test.exs`
  and `login_discovery_runtime_config_test.exs`.

  `System.cmd/3`'s `env:` MERGES onto this VM's environment, so EVERY variable under
  test is explicitly set or `nil` in every case (never inherited); `MIX_TEST_PARTITION`
  and `MIX_BUILD_PATH` are nil. Sentinel values are distinctive and are not secrets;
  SMTP values are placeholders. `@moduletag :slow`; the `:prod` cases are also tagged
  `:prod_build` (they need `_build/prod`, precompiled in `setup_all`).
  """

  use ExUnit.Case, async: false

  @moduletag :slow

  # Built at compile time, never a 64-hex literal (the no-secret guard scans tracked files).
  @master_key String.duplicate("3f1c9a2e7b4d6081", 4)

  @marker_var "LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION"
  @sentinel "zz-marker-70011"
  @probe ~S|IO.puts("RESULT " <> inspect({Application.get_env(:letflow, Letflow.Routers.LoginDiscovery), Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier)[:adapter]}))|

  # Every variable this test cares about, nil unless a case overrides it.
  @blank_env %{
    "LETFLOW_LOGIN_DISCOVERY_ENABLED" => nil,
    "LETFLOW_LOGIN_DISCOVERY_MODE" => nil,
    "LETFLOW_TRUSTED_PROXIES" => nil,
    "LETFLOW_MAIL_ADAPTER" => nil,
    "LETFLOW_SMTP_HOST" => nil,
    "LETFLOW_SMTP_PORT" => nil,
    "LETFLOW_SMTP_USERNAME" => nil,
    "LETFLOW_SMTP_PASSWORD" => nil,
    "LETFLOW_SMTP_TLS" => nil,
    "LETFLOW_MAIL_FROM" => nil,
    "LETFLOW_PUBLIC_BASE_URL" => nil,
    "LETFLOW_MAIL_TIMEOUT_MS" => nil,
    "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS" => nil,
    "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID" => nil,
    "LOG_LEVEL" => nil,
    @marker_var => nil
  }

  @smtp %{
    "LETFLOW_MAIL_ADAPTER" => "smtp",
    "LETFLOW_SMTP_HOST" => "smtp.example.com",
    "LETFLOW_SMTP_PORT" => "587",
    "LETFLOW_SMTP_USERNAME" => "placeholder-user",
    "LETFLOW_SMTP_PASSWORD" => "placeholder-pass",
    "LETFLOW_MAIL_FROM" => "login@example.com",
    "LETFLOW_PUBLIC_BASE_URL" => "https://app.example.com"
  }

  setup_all do
    # setup_all has no per-test timeout: absorb the cold compiles here.
    for mix_env <- ["prod", "dev"] do
      {output, status} =
        System.cmd("mix", ["compile"],
          env: [{"MIX_ENV", mix_env}, {"MIX_TEST_PARTITION", nil}, {"MIX_BUILD_PATH", nil}],
          stderr_to_stdout: true,
          cd: File.cwd!()
        )

      if status != 0, do: raise("precompiling MIX_ENV=#{mix_env} failed (#{status}):\n#{output}")
    end

    :ok
  end

  defp hex32, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  # overrides: map of VAR => string | nil, merged over the all-nil @blank_env.
  defp boot(mix_env, overrides) do
    vars =
      Map.merge(
        %{
          "MIX_ENV" => mix_env,
          "MIX_TEST_PARTITION" => nil,
          "MIX_BUILD_PATH" => nil,
          "LETFLOW_SECRETS_MASTER_KEY" => @master_key,
          "LETFLOW_LOGIN_DIRECTORY_PEPPER" => hex32(),
          "LETFLOW_LOGIN_DIRECTORY_PEPPER_ID" => "cur-1",
          "DATABASE_URL" => "ecto://dummy:dummy@localhost/dummy"
        },
        Map.merge(@blank_env, overrides)
      )

    System.cmd("mix", ["run", "--no-start", "-e", @probe],
      env: Map.to_list(vars),
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end

  defp prod_enabled(extra) do
    Map.merge(
      %{"LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true", "LETFLOW_TRUSTED_PROXIES" => "10.0.0.0/8"},
      extra
    )
  end

  defp assert_boots(output, status) do
    assert status == 0, "expected exit 0, got #{status} with output:\n#{output}"
    assert output =~ "RESULT "
  end

  defp assert_refused(output, status, variable) do
    refute status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    refute output =~ "RESULT", "boot must not reach the probe:\n#{output}"
    assert output =~ variable, "the message must name #{variable}:\n#{output}"
    assert output =~ "email-first login is enabled outside dev/test"
  end

  describe "MIX_ENV=prod, enabled=true, valid trusted proxies: the marker" do
    @describetag :prod_build

    for {label, marker} <- [
          unset: nil,
          blank: "",
          whitespace_only: "        ",
          seven_chars: "abcdefg",
          seven_plus_padding: "  abcdefg  "
        ] do
      test "#{label} (with a valid SMTP adapter) refuses boot" do
        {output, status} =
          boot("prod", prod_enabled(Map.put(@smtp, @marker_var, unquote(marker))))

        assert_refused(output, status, @marker_var)
      end
    end

    test "exactly 8 characters (with a valid SMTP adapter) boots" do
      {output, status} = boot("prod", prod_enabled(Map.put(@smtp, @marker_var, "abcdefgh")))
      assert_boots(output, status)
    end

    test "a too-short sentinel marker is not echoed" do
      short = "zz-9"
      {output, status} = boot("prod", prod_enabled(Map.put(@smtp, @marker_var, short)))
      assert_refused(output, status, @marker_var)
      refute output =~ short
    end
  end

  describe "MIX_ENV=prod, enabled=true, valid marker: the adapter" do
    @describetag :prod_build

    for {label, adapter} <- [unset: nil, noop: "noop", noop_padded: "  noop  "] do
      test "#{label} refuses boot" do
        {output, status} =
          boot(
            "prod",
            prod_enabled(%{@marker_var => @sentinel, "LETFLOW_MAIL_ADAPTER" => unquote(adapter)})
          )

        assert_refused(output, status, "LETFLOW_MAIL_ADAPTER")
        refute output =~ @sentinel
        refute output =~ ~r/noop/i, "the adapter value/module must not be echoed:\n#{output}"
      end
    end

    test "smtp with the complete SMTP environment boots, selects the Smtp adapter and keeps the mount true" do
      {output, status} = boot("prod", prod_enabled(Map.put(@smtp, @marker_var, @sentinel)))
      assert_boots(output, status)
      assert output =~ "RESULT {[enabled: true], Letflow.LoginDiscovery.Notifier.Smtp}"
      refute output =~ @sentinel
      refute output =~ "placeholder-pass"
    end

    test "smtp with an incomplete SMTP environment is still refused by REQ-441's block, not silently passed" do
      {output, status} =
        boot(
          "prod",
          prod_enabled(%{
            @marker_var => @sentinel,
            "LETFLOW_MAIL_ADAPTER" => "smtp",
            "LETFLOW_SMTP_HOST" => "smtp.example.com"
          })
        )

      refute status == 0
      refute output =~ "RESULT"
      refute output =~ @sentinel
    end

    test "the marker is checked before the adapter: both missing names the marker" do
      {output, status} = boot("prod", prod_enabled(%{}))
      assert_refused(output, status, @marker_var)
      refute output =~ "LETFLOW_MAIL_ADAPTER does not select"
    end
  end

  describe "MIX_ENV=prod: the gate stays out of the way" do
    @describetag :prod_build

    test "enabled=false boots with no marker and no adapter" do
      {output, status} = boot("prod", %{"LETFLOW_LOGIN_DISCOVERY_ENABLED" => "false"})
      assert_boots(output, status)
      assert output =~ "RESULT {[enabled: false],"
    end

    test "enabled unset defaults to false in :prod and boots with no marker and no adapter" do
      {output, status} = boot("prod", %{})
      assert_boots(output, status)
      assert output =~ "RESULT {[enabled: false],"
    end

    test "REQ-439 precedes: enabled=true with an empty trusted-proxy list is still refused for the proxy list" do
      {output, status} =
        boot(
          "prod",
          Map.merge(@smtp, %{
            "LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true",
            @marker_var => @sentinel
          })
        )

      refute status == 0
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      refute output =~ "email-first login is enabled outside dev/test"
      refute output =~ @sentinel
    end
  end

  describe "dev and test are never refused" do
    for mix_env <- ["dev", "test"] do
      test "MIX_ENV=#{mix_env} with enabled=true, no marker and no adapter boots" do
        {output, status} =
          boot(unquote(mix_env), %{"LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true"})

        assert_boots(output, status)
        assert output =~ "RESULT {[enabled: true],"
      end

      test "MIX_ENV=#{mix_env} with enabled=true, a blank marker and adapter=noop boots" do
        {output, status} =
          boot(unquote(mix_env), %{
            "LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true",
            @marker_var => "  ",
            "LETFLOW_MAIL_ADAPTER" => "noop"
          })

        assert_boots(output, status)
      end
    end

    test "unset enabled defaults to true in dev (the exemption does not depend on a variable)" do
      {output, status} = boot("dev", %{})
      assert_boots(output, status)
      assert output =~ "RESULT {[enabled: true], Letflow.LoginDiscovery.Notifier.Noop}"
    end
  end
end
