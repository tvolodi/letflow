defmodule Letflow.NoSmtpSecretGuardTest do
  @moduledoc """
  REQ-441 AC6 (spec `test/specs/REQ-441.md`; SECURITY-REVIEWER step 02c finding 10):
  NO SECRET IN THE REPOSITORY.

  A content scan over the TRACKED tree (`git ls-files`) finds no value assigned to
  the SMTP username or password variable: not as a `NAME=value` environment assignment,
  not as a quoted `NAME: "value"` / `"NAME": "value"` mapping entry, and not as a literal
  value in a `put_env("NAME", "value")` call. Names, blank assignments (`NAME=`) and
  assignments whose value is a variable are fine -- that is exactly how `.env.example`,
  the docs and the tests refer to them.

  The scan is not vacuous: the patterns are first proven against known-bad and
  known-good samples, and the variable names ARE found in tracked files. The patterns
  are built from pieces so this file does not trip its own scan. The two `.env.example`
  files must carry every REQ-441 variable as a bare `NAME=` line with nothing after it.

  Tests need no `NAME=value` text: they use `System.put_env/2` with names held in module
  attributes and values built at compile time (`Letflow.Test.SmtpHelpers`).
  """

  use ExUnit.Case, async: true

  # Built from pieces, at run time (a compiled regex does not belong in a module
  # attribute on current OTP), so the literal assignment text never appears in this file.
  defp patterns do
    names = "LETFLOW_SMTP_" <> "(?:PASS" <> "WORD|USER" <> "NAME)"

    [
      env_assignment:
        Regex.compile!(names <> ~S{=(?:"[^"\s]+"|'[^'\s]+'|[A-Za-z0-9_/+$@%!~^&?-][^\s`]*)}),
      mapping_entry: Regex.compile!(names <> ~S{["']?\s*:\s*["'][^"'\s]+["']}),
      put_env_literal: Regex.compile!(~S{["']} <> names <> ~S{["']\s*,\s*["'][^"']+["']})
    ]
  end

  defp flagged?(line), do: Enum.any?(patterns(), fn {_kind, re} -> Regex.match?(re, line) end)

  @max_bytes 4_000_000

  @mail_variables ~w(LETFLOW_MAIL_ADAPTER LETFLOW_SMTP_HOST LETFLOW_SMTP_PORT
                     LETFLOW_SMTP_USERNAME LETFLOW_SMTP_PASSWORD LETFLOW_SMTP_TLS
                     LETFLOW_MAIL_FROM LETFLOW_PUBLIC_BASE_URL LETFLOW_MAIL_TIMEOUT_MS)

  defp tracked_files do
    {out, 0} = System.cmd("git", ["ls-files", "-z"], stderr_to_stdout: true)
    out |> String.split(<<0>>, trim: true)
  end

  describe "the scan patterns" do
    # samples are assembled from pieces for the same reason as the patterns
    @user "LETFLOW_SMTP_" <> "USERNAME"
    @pass "LETFLOW_SMTP_" <> "PASSWORD"

    test "catch every shape of an assigned value" do
      for sample <- [
            @pass <> "=hunter2",
            @user <> "=alice@example.org",
            "export " <> @pass <> "=hunter2",
            "  - " <> @pass <> "=hunter2",
            @pass <> ~S|="hunter2"|,
            @pass <> "='hunter2'",
            @pass <> ~S|: "hunter2"|,
            ~s|"#{@pass}": "hunter2"|,
            ~s|System.put_env("#{@pass}", "hunter2")|,
            @pass <> "=changeme"
          ] do
        assert flagged?(sample), "pattern set missed: #{sample}"
      end
    end

    test "do not flag names, blank assignments or variable references" do
      for sample <- [
            @pass <> "=",
            @user <> "=   ",
            "`" <> @pass <> "=` and `" <> @user <> "=` with nothing after",
            @pass <> "= and the next word",
            ~s|@pass_var "#{@pass}"|,
            ~s|System.put_env("#{@pass}", value)|,
            ~s|System.put_env(@pass_var, @pass)|,
            @pass <> ~S|=""|,
            "LETFLOW_MAIL_FROM=noreply@example.org",
            "the " <> @pass <> " variable is read at the point of use"
          ] do
        refute flagged?(sample), "pattern set flagged a non-assignment: #{sample}"
      end
    end
  end

  describe "AC6: the tracked tree" do
    test "no tracked file assigns a value to the SMTP username or password variable" do
      files = tracked_files()
      assert length(files) > 1_000, "git ls-files returned #{length(files)} files"

      scanned =
        for path <- files,
            File.regular?(path),
            %File.Stat{size: size} = File.stat!(path),
            size <= @max_bytes,
            content = File.read!(path),
            String.valid?(content),
            :binary.match(content, "LETFLOW_SMTP_") != :nomatch,
            do: {path, content}

      hits =
        for {path, content} <- scanned,
            {line, number} <- content |> String.split("\n") |> Enum.with_index(1),
            {kind, re} <- patterns(),
            Regex.match?(re, line),
            do: "#{path}:#{number} (#{kind})"

      assert hits == [],
             "a value is assigned to an SMTP credential variable:\n" <> Enum.join(hits, "\n")

      # not vacuous: the variable NAMES are present in tracked files (the example env files)
      scanned_paths = Enum.map(scanned, &elem(&1, 0))
      assert ".env.example" in scanned_paths
      assert "deploy/.env.example" in scanned_paths
      assert "config/runtime.exs" in scanned_paths
    end

    test ".env.example and deploy/.env.example name every REQ-441 variable with NO value" do
      for path <- [".env.example", "deploy/.env.example"] do
        lines = path |> File.read!() |> String.split(~r/\r?\n/)

        for name <- @mail_variables do
          assignments = Enum.filter(lines, &String.starts_with?(&1, name <> "="))

          assert assignments == [name <> "="],
                 "#{path}: expected exactly the bare line #{name}= , got #{inspect(assignments)}"
        end
      end
    end

    test "the two credential lines are exactly 'NAME=' (quoted)" do
      for path <- [".env.example", "deploy/.env.example"] do
        lines = path |> File.read!() |> String.split(~r/\r?\n/)
        assert (@user <> "=") in lines
        assert (@pass <> "=") in lines
      end
    end

    test "config/runtime.exs and the adapter never default a credential" do
      for path <- ["config/runtime.exs", "lib/letflow/login_discovery/notifier/smtp.ex"] do
        src = File.read!(path)

        # no `System.get_env(name, default)` and no `|| "literal"` fallback on the credentials
        refute src =~ ~r/System\.get_env\(\s*"#{@user}"\s*,/
        refute src =~ ~r/System\.get_env\(\s*"#{@pass}"\s*,/
        refute src =~ ~r/System\.get_env\(\s*"#{@pass}"\s*\)\s*\|\|/
        refute src =~ ~r/System\.get_env\(\s*"#{@user}"\s*\)\s*\|\|/
      end
    end
  end
end
