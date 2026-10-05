defmodule Letflow.LoginDirectoryRuntimeConfigTest do
  @moduledoc """
  REQ-435 / 0043 D-C -- the boot-check matrix of `config/runtime.exs` for the four
  login-directory variables (`LETFLOW_LOGIN_DIRECTORY_PEPPER`, `_PEPPER_ID`,
  `_PEPPER_PREVIOUS`, `_PEPPER_PREVIOUS_ID`); design
  `lib/letflow/design/req434-email-first-login-directory.md` §2.2 and §15.1
  item 5. See `test/specs/REQ-435.md`.

  Same technique and for the same reason as `secrets_runtime_config_test.exs`:
  `config/runtime.exs` runs once, at BEAM boot, so the only way to observe a
  boot-time `raise` is a child `mix run` with a controlled environment. The
  child uses `--no-start` (config is evaluated, no application or database is
  started) and `MIX_ENV=dev`, because `config/test.exs` injects fallback values
  for the pepper and the key id when they are unset, which would silently turn
  every "absent" case into a success.

  `System.cmd/3`'s `env:` MERGES onto this process's environment, so every
  variable under test is explicitly set or explicitly `nil`-ed in every case
  (never left to inherit, and never an empty string: an empty value is
  indistinguishable from an unset one on this host). `MIX_TEST_PARTITION` and
  `MIX_BUILD_PATH` are nil-ed so `config/dev.exs`'s ISS-0015 guard does not fire.

  Every non-fixed pepper is generated at run time; no secret-shaped literal is
  written in this file (the no-secret guard scans `test/` too). The probe prints
  key ids only, never a pepper. Each failing case asserts a non-zero exit, a
  message naming the offending variable, and that NO value that was supplied
  appears in the output (INV-4).

  `@moduletag :slow` (run with `--include slow`): each case boots a fresh `mix run`.
  `async: false` so the child VMs do not pile up on a memory-limited host.
  """

  use ExUnit.Case, async: false

  @moduletag :slow

  @pepper "LETFLOW_LOGIN_DIRECTORY_PEPPER"
  @pepper_id "LETFLOW_LOGIN_DIRECTORY_PEPPER_ID"
  @previous "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS"
  @previous_id "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID"
  @master "LETFLOW_SECRETS_MASTER_KEY"

  @probe ~s|k = Application.fetch_env!(:letflow, :login_directory_keys); | <>
           ~s|IO.puts("PROBE current=" <> k[:current].id <> " previous=" <> | <>
           ~s|inspect(k[:previous] && k[:previous].id))|

  defp hex32, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  # Runs the probe in a child with a fully controlled environment. `overrides`
  # is a map of variable name -> value | nil, applied over a valid baseline
  # (fresh master key, fresh current pepper, id "cur-1", no previous pair).
  defp boot(overrides) do
    baseline = %{
      @master => hex32(),
      @pepper => hex32(),
      @pepper_id => "cur-1",
      @previous => nil,
      @previous_id => nil
    }

    env =
      baseline
      |> Map.merge(overrides)
      |> Map.merge(%{"MIX_ENV" => "dev", "MIX_TEST_PARTITION" => nil, "MIX_BUILD_PATH" => nil})
      |> Enum.to_list()

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", @probe],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    supplied = for {_name, value} <- overrides, is_binary(value), do: value
    %{output: output, status: status, supplied: supplied}
  end

  defp assert_boot_fails(overrides, variable, fragment) do
    %{output: output, status: status, supplied: supplied} = boot(overrides)

    refute status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    refute output =~ "PROBE", "boot must not reach the probe:\n#{output}"
    assert output =~ variable, "message must name #{variable}:\n#{output}"
    assert output =~ fragment, "message must contain #{inspect(fragment)}:\n#{output}"

    for value <- supplied, String.trim(value) != "" do
      refute output =~ String.trim(value), "output must not echo a supplied value"
    end

    :ok
  end

  describe "required current pair" do
    test "absent pepper fails with 'is missing'" do
      assert_boot_fails(%{@pepper => nil}, @pepper, "is missing")
    end

    test "absent key id fails with 'is missing'" do
      assert_boot_fails(%{@pepper_id => nil}, @pepper_id, "is missing")
    end
  end

  describe "key id format [a-z0-9_-]{1,32}" do
    for {label, bad} <- [
          {"uppercase", "LEAKYIDUPPER"},
          {"33 characters", String.duplicate("a", 33)},
          {"a space", "has space-leakyid"},
          {"a dot", "dot.leakyid"},
          {"a trailing newline", "leakyid-nl\n"}
        ] do
      test "malformed key id (#{label}) fails with 'is malformed'" do
        assert_boot_fails(%{@pepper_id => unquote(bad)}, @pepper_id, "is malformed")
      end
    end
  end

  describe "pepper value checks" do
    test "not 64 hex characters (non-hex text) fails with 'is malformed'" do
      assert_boot_fails(%{@pepper => "not-hex-leaky-pepper-value"}, @pepper, "is malformed")
    end

    test "63 hex characters fails with 'is malformed'" do
      assert_boot_fails(%{@pepper => binary_part(hex32(), 0, 63)}, @pepper, "is malformed")
    end

    test "65 hex characters fails with 'is malformed'" do
      assert_boot_fails(%{@pepper => hex32() <> "a"}, @pepper, "is malformed")
    end

    test "uppercase hex fails with 'is malformed'" do
      assert_boot_fails(%{@pepper => String.upcase(hex32())}, @pepper, "is malformed")
    end

    test "all-zero fails as trivially guessable" do
      assert_boot_fails(%{@pepper => String.duplicate("0", 64)}, @pepper, "trivially-guessable")
    end

    test "all-0xFF fails as trivially guessable" do
      assert_boot_fails(%{@pepper => String.duplicate("f", 64)}, @pepper, "trivially-guessable")
    end

    test "equal to the secrets master key fails as 'a distinct secret'" do
      shared = hex32()

      assert_boot_fails(
        %{@pepper => shared, @master => shared},
        @pepper,
        "distinct secret"
      )
    end
  end

  describe "previous pair (rotation)" do
    test "previous pepper without its id fails: both or neither" do
      assert_boot_fails(%{@previous => hex32()}, @previous, "set together")
    end

    test "previous id without its pepper fails: both or neither" do
      assert_boot_fails(%{@previous_id => "prev-1"}, @previous_id, "set together")
    end

    test "previous pepper equal to the current pepper fails" do
      same = hex32()

      assert_boot_fails(
        %{@pepper => same, @previous => same, @previous_id => "prev-1"},
        @previous,
        "must differ"
      )
    end

    test "previous id equal to the current id fails" do
      assert_boot_fails(
        %{@previous => hex32(), @previous_id => "cur-1"},
        @previous_id,
        "must differ"
      )
    end

    test "previous pepper failing the hex check fails" do
      assert_boot_fails(
        %{@previous => "leaky-previous-not-hex", @previous_id => "prev-1"},
        @previous,
        "is malformed"
      )
    end

    test "previous pepper all-zero fails as trivially guessable" do
      assert_boot_fails(
        %{@previous => String.duplicate("0", 64), @previous_id => "prev-1"},
        @previous,
        "trivially-guessable"
      )
    end

    test "previous pepper equal to the master key fails" do
      shared = hex32()

      assert_boot_fails(
        %{@previous => shared, @previous_id => "prev-1", @master => shared},
        @previous,
        "distinct secret"
      )
    end

    test "malformed previous id fails" do
      assert_boot_fails(
        %{@previous => hex32(), @previous_id => "PREV-LEAKY"},
        @previous_id,
        "is malformed"
      )
    end
  end

  describe "valid configurations boot" do
    test "current only: boots with previous: nil" do
      %{output: output, status: status} = boot(%{})

      assert status == 0, output
      assert output =~ ~s|PROBE current=cur-1 previous=nil|
    end

    test "current plus previous: boots and both ids are visible to the probe" do
      %{output: output, status: status} = boot(%{@previous => hex32(), @previous_id => "prev-1"})

      assert status == 0, output
      assert output =~ ~s|PROBE current=cur-1 previous="prev-1"|
    end

    test "a whitespace-only previous pair counts as unset (D19)" do
      %{output: output, status: status} = boot(%{@previous => "   ", @previous_id => "  "})

      assert status == 0, output
      assert output =~ "previous=nil"
    end
  end
end
