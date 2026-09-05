defmodule Mix.Tasks.Letflow.CheckAsyncSandboxReachability do
  @shortdoc "Fails when an async:true test file reaches Ecto.Adapters.SQL.Sandbox.mode/2"

  @moduledoc """
  Implements ISS-0512: mechanically enforces the invariant that only discipline
  protected before -- an `async: true` ExUnit test file must never (directly or
  transitively, via `Letflow.TenantFixture.provisioned_tenant!/1`) reach
  `Ecto.Adapters.SQL.Sandbox.mode/2`. `Sandbox.mode/2` checks in every connection
  in the pool when the mode changes, so a bystander `async: true` file reaching
  it corrupts concurrently-running async tests. This is the third recurrence in
  this family (ISS-0113 OQ-5 flagged the general risk but only guarded a file
  that itself calls `mode/2` directly, never a bystander file reached
  transitively; ISS-0480 restored the invariant by construction for two files
  but nothing prevented recurrence). Design authority:
  `lib/letflow/design/iss0512-async-sandbox-mode-check.md`, independently
  validated (`handoffs/WF03-ISS0512-20260905/step-02b-code-design-validator.json`).

  Mirrors `lib/mix/tasks/letflow.lint_handoffs.ex`'s own shape: a plain static
  textual scan over files already on disk, with a small, closed, named
  allowlist (`@verified_safe` below) instead of a wildcard/pattern exemption --
  same discipline `lint_handoffs.ex`'s own `@grandfathered` comment insists on:
  every entry is one exact file, a NEW file hitting the same rule is never
  covered by an existing entry.

  ## What counts as a real `async: true` declaration (design §2)

  Anchored per physical line: `^\\s*use\\s+[A-Za-z0-9_.]+\\s*,.*\\basync:\\s*true\\b`
  -- the line's first non-whitespace token must be the literal token `use`.
  This alone rejects every moduledoc-prose and `#`-comment false positive found
  in this codebase (none of them start the line with a bare `use` token). A
  file is a real async:true file iff at least one line matches this anchor.

  ## What counts as a real call site reaching `Sandbox.mode/2` (design §3)

  Two independent per-line patterns, evaluated only inside a real async:true
  file, each excluding matches inside a `@moduledoc \"\"\"..\"\"\"` span or on a
  `#`-comment line:

    * §3(a) -- `provisioned_tenant!\\s*\\(` (unqualified: no other module in
      this codebase defines a same-named function).
    * §3(b) -- `(Ecto\\.Adapters\\.SQL\\.)?Sandbox\\.mode\\s*\\(` -- a bare or
      fully-qualified `Sandbox.mode(` call directly in the test file.

  `provisioned_tenant!/1`'s own body calls `Sandbox.mode/2` unconditionally as
  its literal first statement, before any `template:` option is even read, so
  detecting a call to it is already sufficient to prove the file reaches
  `mode/2` -- the checker never needs to model the second hop to
  `Letflow.TenantTemplate.ensure_template!/0` or parse the `template:` option.

  ## The `@verified_safe` allowlist (design §5)

  Exactly two entries, each an exact file path citing the issue that verified
  it. A candidate violation whose path is on this list is reported
  (informationally) but does not fail the build; a candidate violation whose
  path is NOT on this list fails the build. No wildcard, no directory-prefix,
  no rule-level blanket exemption -- adding a 3rd entry requires a deliberate
  commit that also performs (and cites, in that file's own moduledoc) ISS-0113
  §3's three-mechanism verification procedure.

  ## What this task deliberately does NOT check

  General Elixir call-graph analysis, macro expansion, `apply/3`, following
  into arbitrary `lib/letflow/` application code (zero `Sandbox.mode` hits
  there today), or a direct, `provisioned_tenant!/1`-free call to
  `Letflow.TenantTemplate.ensure_template!/0` (no such call site exists in this
  codebase today; if one is ever added, the fix is a third pattern,
  `ensure_template!\\s*\\(`, with the same two exclusions -- not added
  proactively since it would have zero effect against the current corpus).
  Multi-line `use` declarations are also not handled (none exist in this
  codebase today) -- a future wrapped `use Foo,\\n  async: true` would silently
  fail to be classified as async:true.

  `test/support/tenant_schema_reaper.ex` and `test/support/tenant_template.ex`
  are legitimate `Sandbox.mode/2` callers and are never the SUBJECT of this
  check -- excluded structurally by the file-selection step (they don't match
  `test/**/*_test.exs`, and even if scanned, neither contains a real
  `use ..., async: true` line).

  ## Usage

      mix letflow.check_async_sandbox_reachability
      mix letflow.check_async_sandbox_reachability --dir <path>

  Exits non-zero (`Mix.raise/1`) iff at least one new (non-allowlisted)
  violation exists.

  ### `--dir <path>`

  Following `letflow.lint_handoffs.ex`'s own `--dir <path>` precedent
  (ISS-0440) exactly: overrides the `test` root the `test/**/*_test.exs`
  wildcard is rooted at. With no `--dir`, behavior is unchanged from the
  hardcoded default (CI's own invocation, via the `letflow.check` alias). An
  explicitly-supplied `--dir` that discovers zero matching files is a hard
  usage error (`Mix.raise/1`), never a silent clean pass -- this exists so a
  regression test can point the checker at a scratch directory holding a
  synthetic fixture without ever placing that fixture under the real `test/`
  tree (which would itself be picked up and executed by a plain `mix test`).
  """

  use Mix.Task

  @default_dir "test"
  @rule String.duplicate("=", 72)

  # Design §5 -- exactly two entries, each an exact file path, each citing the
  # issue that verified it. No wildcard, no directory-prefix. A NEW file
  # hitting this rule is NOT covered by this list and fails the build.
  @verified_safe [
    {"test/letflow/secrets_test.exs",
     "ISS-0113/ISS-0423 -- three-mechanism procedure passed, see the file's own moduledoc"},
    {"test/letflow/webhooks_test.exs",
     "ISS-0113/ISS-0423 -- three-mechanism procedure passed, see the file's own moduledoc"}
  ]

  @async_true_re ~r/^\s*use\s+[A-Za-z0-9_.]+\s*,.*\basync:\s*true\b/
  @provisioned_tenant_re ~r/provisioned_tenant!\s*\(/
  @sandbox_mode_re ~r/(Ecto\.Adapters\.SQL\.)?Sandbox\.mode\s*\(/

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    dir = resolve_dir(args)

    files = test_files(dir)

    guard_empty_scope(dir, files)

    contents = Map.new(files, &{&1, File.read!(&1)})

    async_true_files = Enum.filter(files, &async_true_file?(Map.fetch!(contents, &1)))

    findings =
      async_true_files
      |> Enum.map(&scan_file(&1, Map.fetch!(contents, &1)))
      |> Enum.reject(&is_nil/1)

    {new, permitted} = Enum.split_with(findings, &(&1.verified_safe_citation == nil))

    print_report(findings, new, permitted)

    total_new = length(new)

    IO.puts(@rule)

    if total_new > 0 do
      IO.puts("letflow.check_async_sandbox_reachability: FAIL -- #{total_new} new violation(s).")

      IO.puts(@rule)

      Mix.raise(
        "letflow.check_async_sandbox_reachability found #{total_new} new violation(s) -- " <>
          "see output above"
      )
    else
      IO.puts(
        "letflow.check_async_sandbox_reachability: OK -- #{length(async_true_files)} " <>
          "async:true test file(s) scanned under #{inspect(dir)}, #{length(findings)} reach " <>
          "Sandbox.mode/2 (#{length(permitted)} permitted, verified exceptions), 0 new violations."
      )

      IO.puts(@rule)
      :ok
    end
  end

  # -- CLI flag parsing (mirrors letflow.lint_handoffs.ex's --dir handling) --

  @spec resolve_dir([String.t()]) :: String.t()
  def resolve_dir(args) do
    case find_dir_flag(args) do
      :not_present ->
        @default_dir

      {:ok, value} ->
        value

      :missing_value ->
        Mix.raise("letflow.check_async_sandbox_reachability: --dir given with no path argument")
    end
  end

  defp find_dir_flag(["--dir", value | _rest]), do: {:ok, value}
  defp find_dir_flag(["--dir"]), do: :missing_value
  defp find_dir_flag([_other | rest]), do: find_dir_flag(rest)
  defp find_dir_flag([]), do: :not_present

  # An explicitly-supplied --dir that discovers zero files is a hard usage
  # error, not a silent clean pass -- never let a scoped run masquerade as a
  # full-corpus green result. Does not apply to the default @default_dir
  # itself (a genuinely empty real test/ tree is a separate, pre-existing
  # edge case, not a --dir misuse symptom).
  @spec guard_empty_scope(dir :: String.t(), files :: [String.t()]) :: :ok | no_return()
  def guard_empty_scope(dir, files) do
    if files == [] and dir != @default_dir do
      Mix.raise(
        "letflow.check_async_sandbox_reachability: --dir #{inspect(dir)} discovered 0 files -- " <>
          "refusing to report success for an empty or non-existent scan target"
      )
    else
      :ok
    end
  end

  # -- discovery --------------------------------------------------------------

  @spec test_files(dir :: String.t()) :: [String.t()]
  def test_files(dir \\ @default_dir) do
    Path.wildcard(Path.join(dir, "**/*_test.exs"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  # -- classification (design §2/§3) -------------------------------------------

  # Pure: takes file content as a string, returns whether it's a real
  # async:true file. Exposed as a public function so it is directly testable
  # against synthetic in-memory strings (design §8.1) without touching the
  # filesystem.
  @spec async_true_file?(content :: String.t()) :: boolean()
  def async_true_file?(content) do
    content
    |> String.split("\n")
    |> Enum.any?(&Regex.match?(@async_true_re, &1))
  end

  # Pure: takes file content, returns the list of real §3(a)/§3(b) matches, as
  # `%{pattern: :provisioned_tenant | :sandbox_mode, line_number: pos_integer(),
  # line_text: String.t()}`. Excludes matches inside a `@moduledoc """..."""`
  # span or on a `#`-comment line.
  @spec real_call_sites(content :: String.t()) :: [map()]
  def real_call_sites(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, line_number}, {in_moduledoc?, acc} ->
      cond do
        moduledoc_open?(line) ->
          {true, acc}

        in_moduledoc? and moduledoc_close?(line) ->
          {false, acc}

        in_moduledoc? ->
          {true, acc}

        comment_line?(line) ->
          {false, acc}

        true ->
          {false, acc ++ line_matches(line, line_number)}
      end
    end)
    |> elem(1)
  end

  defp moduledoc_open?(line), do: Regex.match?(~r/^\s*@moduledoc\s+"""\s*$/, line)
  defp moduledoc_close?(line), do: Regex.match?(~r/^\s*"""\s*$/, line)
  defp comment_line?(line), do: Regex.match?(~r/^\s*#/, line)

  defp line_matches(line, line_number) do
    []
    |> maybe_add_match(line, line_number, @provisioned_tenant_re, :provisioned_tenant)
    |> maybe_add_match(line, line_number, @sandbox_mode_re, :sandbox_mode)
  end

  defp maybe_add_match(acc, line, line_number, regex, pattern) do
    if Regex.match?(regex, line) do
      [%{pattern: pattern, line_number: line_number, line_text: String.trim(line)} | acc]
    else
      acc
    end
  end

  # -- per-file scan ------------------------------------------------------------

  # Called only on files already confirmed async:true by the caller. Returns
  # nil when the file has no real call site, or a finding map for a candidate
  # violation: `%{path: ..., matches: [...], verified_safe_citation: String.t() | nil}`.
  defp scan_file(path, content) do
    case real_call_sites(content) do
      [] ->
        nil

      matches ->
        %{path: path, matches: matches, verified_safe_citation: verified_safe_citation(path)}
    end
  end

  defp verified_safe_citation(path) do
    Enum.find_value(@verified_safe, fn {safe_path, citation} ->
      if safe_path == path, do: citation
    end)
  end

  # -- output -------------------------------------------------------------------

  defp print_report(_findings, new, permitted) do
    if new != [] do
      IO.puts(@rule)
      IO.puts("NEW VIOLATIONS (fail the build):")

      Enum.each(new, fn finding ->
        Enum.each(finding.matches, fn match ->
          IO.puts(
            "  [ASYNC-SANDBOX] #{finding.path}:#{match.line_number}: async:true file " <>
              "#{pattern_description(match.pattern)} without a @verified_safe entry -- " <>
              "either (a) revert to async: false, or (b) run ISS-0113 §3's three-mechanism " <>
              "verification procedure and add a named @verified_safe entry citing it."
          )

          IO.puts("      #{match.line_text}")
        end)
      end)
    end

    if permitted != [] do
      IO.puts(@rule)
      IO.puts("PERMITTED, VERIFIED EXCEPTIONS (do not fail the build):")

      Enum.each(permitted, fn finding ->
        IO.puts("  #{finding.path}: #{finding.verified_safe_citation}")
      end)
    end
  end

  defp pattern_description(:provisioned_tenant), do: "calls `provisioned_tenant!(`"
  defp pattern_description(:sandbox_mode), do: "calls `Sandbox.mode(`"
end
