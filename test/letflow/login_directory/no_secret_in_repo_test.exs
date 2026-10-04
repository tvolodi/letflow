defmodule Letflow.LoginDirectory.NoSecretInRepoTest do
  @moduledoc """
  REQ-435 / 0043 D-C, design §15.1 item 6 -- the no-secret guard: no working
  login-directory pepper is committed anywhere.

  Scans every tracked (and untracked-but-not-ignored) file under `lib/`,
  `config/`, `test/`, `deploy/`, `.env.example` and `docs/runbooks/` (when it
  exists). A "hit" is a mention of `LETFLOW_LOGIN_DIRECTORY_PEPPER` (which also
  matches `_PREVIOUS`) with a 64-hex run on the same line or within the next
  three lines (an `System.put_env(\\n"NAME",\\n"<hex>"\\n)` assignment spans
  lines). The only permitted hit is the single documented test value in
  `config/test.exs`. `.env.example` must carry the four names with no value.

  The guard's own ability to fail is proven with a seeded violation written to a
  temp file (the hex is generated at run time, so this file holds no secret-shaped
  literal itself). Failure output quotes names and paths only, never a value.
  """

  use ExUnit.Case, async: true

  @roots ["lib/", "config/", "test/", "deploy/", ".env.example", "docs/runbooks/"]
  @names [
    "LETFLOW_LOGIN_DIRECTORY_PEPPER",
    "LETFLOW_LOGIN_DIRECTORY_PEPPER_ID",
    "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS",
    "LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID"
  ]
  @hex64 ~r/(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])/

  # {path, line_number} of every mention that has a 64-hex run within 4 lines.
  defp hits_in(path) do
    lines = path |> File.read!() |> String.split(~r/\r?\n/)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, index} ->
      String.contains?(line, "LETFLOW_LOGIN_DIRECTORY_PEPPER") and
        lines |> Enum.slice(index - 1, 4) |> Enum.join("\n") |> then(&Regex.match?(@hex64, &1))
    end)
    |> Enum.map(fn {_line, index} -> {path, index} end)
  end

  defp scanned_files do
    existing = Enum.filter(@roots, &File.exists?/1)

    {out, 0} =
      System.cmd(
        "git",
        ["ls-files", "--cached", "--others", "--exclude-standard", "--" | existing],
        cd: File.cwd!()
      )

    out |> String.split("\n", trim: true) |> Enum.uniq() |> Enum.filter(&File.regular?/1)
  end

  test "no tracked file assigns a 64-hex value to a login-directory pepper variable, except the one test value" do
    hits = scanned_files() |> Enum.flat_map(&hits_in/1)
    paths = hits |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    assert paths == ["config/test.exs"],
           "unexpected pepper-shaped assignment(s) (path:line): " <>
             inspect(Enum.reject(hits, fn {path, _} -> path == "config/test.exs" end))

    # The documented test value is a single value: every config/test.exs hit
    # resolves to the same 64-hex string.
    values =
      for {path, line} <- hits,
          window = path |> File.read!() |> String.split(~r/\r?\n/) |> Enum.slice(line - 1, 4),
          [hex] <- Regex.scan(@hex64, Enum.join(window, "\n")),
          uniq: true,
          do: String.downcase(hex)

    assert length(values) == 1
  end

  test ".env.example carries the four pepper names with no value" do
    lines = ".env.example" |> File.read!() |> String.split(~r/\r?\n/)

    for name <- @names do
      assert (name <> "=") in lines,
             "#{name}= (empty) missing from .env.example"

      refute Enum.any?(lines, fn line ->
               String.starts_with?(line, name <> "=") and String.trim(line) != name <> "="
             end),
             "#{name} has a value in .env.example"
    end
  end

  describe "the guard can fail (seeded violations)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ld-guard-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, hex: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)}
    end

    test "same-line assignment is flagged", %{dir: dir, hex: hex} do
      path = Path.join(dir, "same_line.sh")
      File.write!(path, "export LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS=#{hex}\n")

      assert [{^path, 1}] = hits_in(path)
    end

    test "multi-line put_env assignment is flagged", %{dir: dir, hex: hex} do
      path = Path.join(dir, "multi_line.exs")

      File.write!(
        path,
        "System.put_env(\n  \"LETFLOW_LOGIN_DIRECTORY_PEPPER\",\n  \"#{String.upcase(hex)}\"\n)\n"
      )

      assert [{^path, 2}] = hits_in(path)
    end

    test "a name with no value, and a 64-hex run far from any name, are not flagged", %{
      dir: dir,
      hex: hex
    } do
      path = Path.join(dir, "benign.env")

      File.write!(
        path,
        "LETFLOW_LOGIN_DIRECTORY_PEPPER=\n" <>
          String.duplicate("# filler\n", 6) <> "OTHER=#{hex}\n"
      )

      assert hits_in(path) == []
    end
  end
end
