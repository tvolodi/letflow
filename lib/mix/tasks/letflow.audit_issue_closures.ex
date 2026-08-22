defmodule Mix.Tasks.Letflow.AuditIssueClosures do
  @shortdoc "Re-checks every closed, github_issue-linked docs/issues/*.yaml entry for evidence"

  @moduledoc """
  Implements ISS-0279: mechanically re-checks every GitHub issue this project tracks
  (via a `github_issue` field in `docs/issues/*.yaml`) that GitHub currently reports as
  `CLOSED`, and flags any such issue that carries **zero comments AND no genuinely
  linked/merged PR reference** as an undocumented closure -- the pattern found in GH#324
  and GH#326 (`docs/issues/ISS-0279.yaml`), where a closure could not even be checked
  against its own reasoning because it stated none.

  ## This is a LOCAL/ON-DEMAND-ONLY check, not part of `mix letflow.check`

  This task shells out to the `gh` CLI and requires live network access to `github.com`.
  Unlike every step currently wired into `mix letflow.check` (which read only local
  filesystem/git state), this task's result depends on an external service's
  reachability and this host's `gh` authentication. **It is deliberately NOT part of the
  `letflow.check` alias** -- folding a network-dependent check into an alias every agent
  runs, including inside sandboxed/offline environments with no GitHub reachability,
  would make that alias fail for reasons unrelated to the code under test. Run this task
  by hand or from a periodic reconciliation pass, not as a blocking pre-merge gate. See
  `lib/letflow/design/iss0279-issue-closure-audit.md` §2.1 for the full rationale
  (including why a graceful-skip-when-`gh`-unavailable variant was rejected rather than
  silently wired in).

  ## What counts as a violation

  A tracked issue (any `docs/issues/*.yaml` entry with a non-nil `github_issue: <n>`
  field) whose live GitHub state is `CLOSED`, where **both**:

    * `comments.totalCount` (or the length of the `comments` array, depending on which
      `gh` reports) is `0`, and
    * `closedByPullRequestsReferences` is empty (no linked/merged PR closed it).

  A closure with either a comment or a linked/merged PR is compliant, regardless of
  which -- matching `ISSUE_QUEUE.md`'s "Closing an issue's GitHub mirror" section and
  `WF-03_issue_resolving.md` Step 5's hardened wording.

  ## Checks

  ### Hard (exit non-zero on any un-grandfathered violation)

    * **ZERO_EVIDENCE** -- as defined above.

  A violation on an issue number not in this module's `@grandfathered` list is a **new**
  regression and fails the run. A violation on a grandfathered issue number is reported
  (the debt stays visible) but does not fail the run -- each grandfathered number is
  listed individually, dated, and traced to the run that discovered it, per
  `letflow.lint_handoffs`'s own "no blanket suppression" convention (ISS-0190). This
  module contains no wildcard or pattern-based grandfathering.

  ## What this task deliberately does NOT check

  Whether a `--comment`'s or a linked PR's *content* is actually good evidence (e.g.
  whether the comment's claim is even true, or whether the linked PR's diff plausibly
  addresses the issue). That is not mechanically decidable from the GitHub API response
  this task reads; it only checks that evidence of *some* form is present at all, exactly
  as `WF-03_issue_resolving.md` Step 5's hard requirement is worded. A separately
  discovered pattern of *false* evidence (an issue closed with a self-contradicting
  comment) is `ISS-0277`/`GH#548`'s concern, not this one.

  ## Usage

      mix letflow.audit_issue_closures

  Requires `gh` on `PATH`, authenticated, with network access to `github.com`. Exits
  non-zero (`Mix.raise/1`) iff (a) at least one un-grandfathered `ZERO_EVIDENCE`
  violation exists, or (b) `gh` itself could not be run for a tracked issue (missing
  binary, auth failure, network error) -- a failure to complete the audit is reported
  distinctly from a completed audit finding violations, but both are non-zero, so a
  caller cannot mistake "couldn't check" for "checked, all clean." See the report
  sections below for the distinction in output.

  ## Discovery notes

  `docs/issues/*.yaml` has no YAML-parsing dependency in this project (confirmed:
  `mix.exs` has no `yaml_elixir`/similar dep). This task follows
  `lib/mix/tasks/letflow.check_requirements_registration.ex`'s own precedent: read each
  file with `File.read!/1` and extract `id:`/`github_issue:` with anchored regexes
  rather than a YAML library.

  The real corpus was found (2026-08-22, this task's first implementation/run) to write
  `github_issue:` in two live surface forms, not just the bare integer the design
  sketch's example regex covers:

      github_issue: 205
      github_issue: "https://github.com/tvolodi/letflow/issues/206"
      github_issue: https://github.com/tvolodi/letflow/issues/1

  `@github_issue_re` below matches all three (an optional leading quote, an optional
  `https://github.com/<owner>/<repo>/issues/` prefix, then the digits) so that a real
  audit run does not silently skip the majority of tracked issues, which use the URL
  form -- skipping them would contradict this task's own purpose of auditing the real
  corpus. This is a data-shape accommodation, not a change to the design's read
  mechanism (still `File.read!/1` + line-oriented `Regex`, no YAML dependency).
  """

  use Mix.Task

  @issues_dir "docs/issues"
  @rule String.duplicate("=", 72)

  @id_re ~r/^id:\s*(\S+)/m
  @github_issue_re ~r{^github_issue:\s*"?(?:https://github\.com/[^/\s]+/[^/\s]+/issues/)?(\d+)}m

  # -- Individually-named pre-existing ZERO_EVIDENCE closures. Populated by
  # ELIXIR-DEV from this task's own first real run against the corpus (see
  # lib/letflow/design/iss0279-issue-closure-audit.md §2.6 for the population
  # procedure). No wildcards, no number ranges: every entry below is one exact
  # GitHub issue number this task actually found violating, on the date measured.
  # A NEW closure hitting the same rule is NOT covered by this list and fails the
  # build -- grandfathering is per-issue, never per-rule or per-range.
  #
  # GH#324 and GH#326 are deliberately NOT here: both were reconciled with real
  # evidence by WF03-ISS0278-20260822 (see docs/issues/ISS-0096.yaml and
  # ISS-0098.yaml) before this task's first run -- confirmed live 2026-08-22 via
  # `gh issue view 324`/`gh issue view 326`, both now carry real comments -- so
  # they no longer violate ZERO_EVIDENCE and must not be grandfathered as if they
  # still did.
  @grandfathered [
    # {issue_number, "YYYY-MM-DD", "note"} -- one tuple per pre-existing violation.
    # Populated from this task's own first real run against the live corpus,
    # 2026-08-22 (WF03-ISS0279-20260822, ELIXIR-DEV). 30 pre-existing
    # ZERO_EVIDENCE closures found; each traced below to the docs/issues/*.yaml
    # record it was found on. See that run's step-03-elixir-dev.json
    # result.summary for the raw `mix letflow.audit_issue_closures` output this
    # list was derived from.
    {68, "2026-08-22",
     "docs/issues/ISS-0012.yaml -- closed with 0 comments, no linked/merged PR"},
    {69, "2026-08-22",
     "docs/issues/ISS-0013.yaml -- closed with 0 comments, no linked/merged PR"},
    {72, "2026-08-22",
     "docs/issues/ISS-0016.yaml -- closed with 0 comments, no linked/merged PR"},
    {75, "2026-08-22",
     "docs/issues/ISS-0019.yaml -- closed with 0 comments, no linked/merged PR"},
    {76, "2026-08-22",
     "docs/issues/ISS-0020.yaml -- closed with 0 comments, no linked/merged PR"},
    {78, "2026-08-22",
     "docs/issues/ISS-0021.yaml -- closed with 0 comments, no linked/merged PR"},
    {79, "2026-08-22",
     "docs/issues/ISS-0022.yaml -- closed with 0 comments, no linked/merged PR"},
    {81, "2026-08-22",
     "docs/issues/ISS-0023.yaml -- closed with 0 comments, no linked/merged PR"},
    {82, "2026-08-22",
     "docs/issues/ISS-0024.yaml -- closed with 0 comments, no linked/merged PR"},
    {84, "2026-08-22",
     "docs/issues/ISS-0026.yaml -- closed with 0 comments, no linked/merged PR"},
    {85, "2026-08-22",
     "docs/issues/ISS-0027.yaml -- closed with 0 comments, no linked/merged PR"},
    {86, "2026-08-22",
     "docs/issues/ISS-0028.yaml -- closed with 0 comments, no linked/merged PR"},
    {89, "2026-08-22",
     "docs/issues/ISS-0030.yaml -- closed with 0 comments, no linked/merged PR"},
    {90, "2026-08-22",
     "docs/issues/ISS-0031.yaml -- closed with 0 comments, no linked/merged PR"},
    {108, "2026-08-22",
     "docs/issues/ISS-0035.yaml -- closed with 0 comments, no linked/merged PR"},
    {113, "2026-08-22",
     "docs/issues/ISS-0036.yaml -- closed with 0 comments, no linked/merged PR"},
    {120, "2026-08-22",
     "docs/issues/ISS-0038.yaml -- closed with 0 comments, no linked/merged PR"},
    {127, "2026-08-22",
     "docs/issues/ISS-0041.yaml -- closed with 0 comments, no linked/merged PR"},
    {372, "2026-08-22",
     "docs/issues/ISS-0117.yaml -- closed with 0 comments, no linked/merged PR"},
    {388, "2026-08-22",
     "docs/issues/ISS-0198.yaml -- closed with 0 comments, no linked/merged PR"},
    {392, "2026-08-22",
     "docs/issues/ISS-0201.yaml -- closed with 0 comments, no linked/merged PR"},
    {447, "2026-08-22",
     "docs/issues/ISS-0218.yaml -- closed with 0 comments, no linked/merged PR"},
    {449, "2026-08-22",
     "docs/issues/ISS-0219.yaml -- closed with 0 comments, no linked/merged PR"},
    {452, "2026-08-22",
     "docs/issues/ISS-0221.yaml -- closed with 0 comments, no linked/merged PR"},
    {454, "2026-08-22",
     "docs/issues/ISS-0222.yaml -- closed with 0 comments, no linked/merged PR"},
    {455, "2026-08-22",
     "docs/issues/ISS-0223.yaml -- closed with 0 comments, no linked/merged PR"},
    {461, "2026-08-22",
     "docs/issues/ISS-0225.yaml -- closed with 0 comments, no linked/merged PR"},
    {466, "2026-08-22",
     "docs/issues/ISS-0228.yaml -- closed with 0 comments, no linked/merged PR"},
    {499, "2026-08-22",
     "docs/issues/ISS-0257.yaml -- closed with 0 comments, no linked/merged PR"},
    {524, "2026-08-22",
     "docs/issues/ISS-0266.yaml -- closed with 0 comments, no linked/merged PR"}
  ]

  @spec grandfathered?(pos_integer()) :: boolean()
  defp grandfathered?(number),
    do: Enum.any?(@grandfathered, fn {n, _date, _note} -> n == number end)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    tracked = tracked_issues(@issues_dir)

    results = Enum.map(tracked, &audit_one/1)

    fetch_errors = Enum.filter(results, &(&1.kind == :fetch_error))
    violations = Enum.filter(results, &(&1.kind == :violation))
    closed_count = Enum.count(results, &(&1.kind in [:violation, :ok]))

    {new, grandfathered} = Enum.split_with(violations, &(!grandfathered?(&1.number)))

    print_new(new)
    print_grandfathered(grandfathered)
    print_fetch_errors(fetch_errors)

    IO.puts(@rule)

    cond do
      fetch_errors != [] or new != [] ->
        IO.puts(
          "letflow.audit_issue_closures: FAIL -- #{length(new)} new violation(s), " <>
            "#{length(fetch_errors)} fetch error(s)."
        )

        IO.puts(@rule)

        Mix.raise(
          "letflow.audit_issue_closures found #{length(new)} new violation(s) and " <>
            "#{length(fetch_errors)} fetch error(s) -- see output above"
        )

      true ->
        IO.puts(
          "letflow.audit_issue_closures: OK -- 0 new violations across #{closed_count} " <>
            "tracked, closed GitHub issues (#{length(grandfathered)} pre-existing grandfathered)."
        )

        IO.puts(@rule)
        :ok
    end
  end

  # -- discovery ------------------------------------------------------------

  @spec tracked_issues(dir :: String.t()) :: [
          %{ref: String.t(), number: integer(), path: String.t()}
        ]
  def tracked_issues(dir \\ @issues_dir) do
    Path.wildcard(Path.join(dir, "*.yaml"))
    |> Enum.sort()
    |> Enum.map(&parse_issue_file/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_issue_file(path) do
    content = File.read!(path)

    case Regex.run(@github_issue_re, content) do
      [_, digits] ->
        %{ref: extract_id(content, path), number: String.to_integer(digits), path: path}

      nil ->
        nil
    end
  end

  defp extract_id(content, path) do
    case Regex.run(@id_re, content) do
      [_, id] -> id
      nil -> Path.basename(path, ".yaml")
    end
  end

  # -- live fetch -------------------------------------------------------------

  @spec fetch_issue(number :: integer()) :: {:ok, map()} | {:error, term()}
  def fetch_issue(number) do
    args = [
      "issue",
      "view",
      Integer.to_string(number),
      "--json",
      "number,state,comments,closedByPullRequestsReferences"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {out, code} ->
        {:error, {:gh_exit, code, String.trim(out)}}
    end
  end

  # -- classification -----------------------------------------------------

  @spec classify(map()) :: :ok | :violation | :not_closed
  def classify(%{"state" => "CLOSED"} = data) do
    comments = Map.get(data, "comments")
    refs = Map.get(data, "closedByPullRequestsReferences", [])

    if comments_empty?(comments) and refs == [] do
      :violation
    else
      :ok
    end
  end

  def classify(_data), do: :not_closed

  defp comments_empty?(list) when is_list(list), do: list == []
  defp comments_empty?(%{"totalCount" => n}), do: n == 0
  defp comments_empty?(_), do: false

  # -- per-issue audit ------------------------------------------------------

  defp audit_one(%{ref: ref, number: number, path: path}) do
    case fetch_issue(number) do
      {:ok, data} ->
        case classify(data) do
          :violation -> %{kind: :violation, ref: ref, number: number, path: path}
          :ok -> %{kind: :ok, ref: ref, number: number, path: path}
          :not_closed -> %{kind: :not_closed, ref: ref, number: number, path: path}
        end

      {:error, reason} ->
        %{kind: :fetch_error, ref: ref, number: number, path: path, reason: reason}
    end
  end

  # -- output ---------------------------------------------------------------

  defp print_new([]), do: :ok

  defp print_new(new) do
    IO.puts(@rule)
    IO.puts("NEW HARD VIOLATIONS (fail the build):")

    Enum.each(new, fn v ->
      IO.puts(
        "  [ZERO_EVIDENCE] GH##{v.number} (#{v.path}): closed with 0 comments and " <>
          "no linked/merged PR reference"
      )
    end)
  end

  defp print_grandfathered([]), do: :ok

  defp print_grandfathered(grandfathered) do
    IO.puts(@rule)
    IO.puts("GRANDFATHERED (pre-existing, dated, do not fail the build):")

    Enum.each(grandfathered, fn v ->
      {_n, date, note} = Enum.find(@grandfathered, fn {n, _d, _note} -> n == v.number end)
      IO.puts("  [ZERO_EVIDENCE] GH##{v.number} (#{v.path}, grandfathered #{date}): #{note}")
    end)
  end

  defp print_fetch_errors([]), do: :ok

  defp print_fetch_errors(fetch_errors) do
    IO.puts(@rule)
    IO.puts("FETCH ERRORS (audit incomplete for these issues -- not counted as pass or fail):")

    Enum.each(fetch_errors, fn v ->
      IO.puts("  GH##{v.number} (#{v.path}): gh error -- #{inspect(v.reason)}")
    end)
  end
end
