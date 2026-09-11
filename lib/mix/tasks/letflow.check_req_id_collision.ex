defmodule Mix.Tasks.Letflow.CheckReqIdCollision do
  @shortdoc "Detects a REQ-NNN id this branch invented colliding with one already on origin/main"

  @moduledoc """
  Implements ISS-0613: `REQ-NNN` id collision detection.

  Design: `lib/letflow/design/iss0613-req-id-collision-check.md`.

  `docs/requirements.yaml`'s own requirement id (`REQ-NNN`) is allocated by a
  session scanning the file for the current highest `REQ-` number and
  incrementing -- a read-then-write race with no lock between the read and
  the write. Two sessions can both read the same max before either pushes,
  and both pick the same next id. This is the exact failure class
  `docs/agents/protocols/ISSUE_QUEUE.md` already documents and fixed for
  `ISS-NNNN` ids; `REQ-NNN` never received the equivalent fix. This task
  closes the gap the way the design document (section 2, direction (b))
  settles on: a **collision-detecting gate**, not a numbering-scheme change --
  a duplicate write must never land on `main` undetected.

  ## Mechanism (design section 3.2)

  Three snapshots of `docs/requirements.yaml` are parsed for `REQ-NNN` ids:

    * the **current working tree** (`File.read!/1` -- this task must see
      uncommitted content too, not just `HEAD`, since its job is to catch a
      collision before it is pushed);
    * the **merge base** of `HEAD` and `origin/main`
      (`git merge-base origin/main HEAD`, then `git show <sha>:<path>`) --
      what this branch looked like before it diverged;
    * **`origin/main`'s current tip** (`git show origin/main:<path>`).

  `added_by_this_branch` is the set of ids present in the working tree but
  absent from the merge-base snapshot -- ids this branch itself introduced
  since diverging. For each such id:

    * absent from `origin/main` -> no finding (nobody else has claimed it).
    * present in `origin/main`, **normalized text identical** -> no finding
      (a legitimate re-push, e.g. this branch already merged or was rebased).
    * present in `origin/main`, **normalized text different** -> genuine
      collision: this branch independently invented an id `main` already
      claimed for something else. Hard failure.

  No `git fetch` is issued by this task -- it trusts the local `origin/main`
  ref exactly as `lib/mix/tasks/letflow.lint_handoffs.ex` already does for
  its own git-shelling checks. That is safe in CI because
  `.github/workflows/ci.yml`'s checkout step always runs with
  `fetch-depth: 0`; in a normal dev workflow the ref is kept current by
  `GIT_MERGE.md`'s existing rebase steps.

  ## Local, first-time-clone tolerance (design section 4)

  If `origin/main` (or the merge base against it) cannot be resolved --
  most commonly a local clone that has never fetched `origin` -- this is a
  **non-fatal skip with a warning**, not a hard failure: CI's own checkout
  always resolves it, so failing a developer environment that simply
  hasn't fetched yet would be a false positive with no useful signal.

  ## Parsing model

  Line-oriented, not YAML -- this project has no YAML dependency (same
  reasoning `Mix.Tasks.Letflow.CheckRequirementsRegistration` already
  states). Only lines after the top-level `requirements:` key are scanned.
  Within that section an entry starts at a line matching two-space
  `- id: ` and runs to the line before the next such line -- the same
  `@entry_start_re` shape `check_requirements_registration` uses, so the two
  tasks stay consistent about what counts as "belonging to" an entry.

  Content comparison normalizes CRLF to LF and strips trailing whitespace
  per line before comparing two entries' raw text -- the same
  CRLF-normalization caution `docs/anti-patterns.md`'s "ISS-NNNN collisions
  keep recurring" entry flags for exactly this class of comparison.

  ## Usage

      mix letflow.check_req_id_collision

  Wired into the `letflow.check` alias immediately after
  `letflow.check_requirements_registration` (`mix.exs`).

  Exits `0` iff no genuine collision is found (including the "skip, cannot
  resolve origin/main locally" case); `Mix.raise/1` otherwise, naming every
  colliding id and both branches' entry text.
  """

  use Mix.Task

  @requirements_file "docs/requirements.yaml"

  @rule String.duplicate("=", 72)

  @requirements_key_re ~r/^requirements:\s*$/
  @entry_start_re ~r/^  - id: /
  @id_line_re ~r/^  - id:\s*(.*?)\s*$/
  @attributed_re ~r/^ {4,}\S/
  @well_formed_id_re ~r/^REQ-\d+$/

  @type entry :: %{line: pos_integer(), text: String.t()}
  @type id_map :: %{String.t() => entry()}

  @type collision :: %{
          id: String.t(),
          branch_entry: entry(),
          main_entry: entry()
        }

  # -- Mix.Task entry point -------------------------------------------------

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    working_tree_ids =
      case File.read(@requirements_file) do
        {:ok, content} ->
          parse_ids(content)

        {:error, reason} ->
          Mix.raise(
            "mix letflow.check_req_id_collision: could not read #{@requirements_file}: " <>
              "#{inspect(reason)}"
          )
      end

    case resolve_git_snapshots() do
      {:skip, reason} ->
        IO.puts(@rule)

        IO.puts(
          "mix letflow.check_req_id_collision: SKIPPED -- origin/main not resolvable " <>
            "locally (#{reason}). Run `git fetch origin main` and re-run this check. " <>
            "CI always resolves this ref (fetch-depth: 0), so this is a local-only gap."
        )

        IO.puts(@rule)
        :ok

      {:ok, merge_base_content, origin_content} ->
        merge_base_ids = parse_ids(merge_base_content)
        origin_ids = parse_ids(origin_content)

        collisions = detect_collisions(working_tree_ids, merge_base_ids, origin_ids)

        if collisions == [] do
          IO.puts(
            "mix letflow.check_req_id_collision: OK -- no REQ-NNN id collision with " <>
              "origin/main."
          )

          :ok
        else
          Mix.raise(render_failure(collisions))
        end
    end
  end

  # -- pure core --------------------------------------------------------------

  @doc """
  Parses one `docs/requirements.yaml`-shaped string into `%{id => entry}`,
  `entry` being that id's line number (in `content`) and full raw entry
  text. Never raises on content -- an id-less or key-less file simply
  produces an empty map, since the only thing this task ever does with the
  result is set-difference and equality comparison, both of which are safe
  against an empty map.
  """
  @spec parse_ids(String.t()) :: id_map()
  def parse_ids(content) when is_binary(content) do
    numbered =
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {line, n} -> {n, line} end)

    case Enum.find_index(numbered, fn {_n, line} -> Regex.match?(@requirements_key_re, line) end) do
      nil ->
        %{}

      idx ->
        numbered
        |> Enum.drop(idx + 1)
        |> split_entries()
        |> Enum.reduce(%{}, fn entry_lines, acc ->
          case entry_lines do
            [{line_no, id_line} | _rest] = full ->
              id = extract_id(id_line)

              if Regex.match?(@well_formed_id_re, id) do
                text = full |> Enum.map(fn {_n, l} -> l end) |> Enum.join("\n")
                Map.put(acc, id, %{line: line_no, text: text})
              else
                acc
              end

            [] ->
              acc
          end
        end)
    end
  end

  @doc """
  Normalizes one entry's raw text for content comparison: CRLF -> LF, and
  trailing whitespace stripped per line. Two entries that normalize equal
  are the same content for collision-detection purposes even if their
  line-ending or trailing-whitespace convention differs.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
  end

  @doc """
  The detection core (design section 3.2, steps 2-3). Pure: takes three
  already-parsed id maps, returns the list of genuine collisions.

  `added_by_this_branch` = ids in `current` absent from `merge_base`. Of
  those, an id absent from `origin` is not a finding; an id present in
  `origin` with content that normalizes identically to `current`'s is not a
  finding (a legitimate re-push); an id present in `origin` with content
  that normalizes differently is a genuine collision.
  """
  @spec detect_collisions(id_map(), id_map(), id_map()) :: [collision()]
  def detect_collisions(current, merge_base, origin) do
    added_by_this_branch = Map.keys(current) -- Map.keys(merge_base)

    added_by_this_branch
    |> Enum.filter(&Map.has_key?(origin, &1))
    |> Enum.filter(fn id ->
      normalize(Map.fetch!(current, id).text) != normalize(Map.fetch!(origin, id).text)
    end)
    |> Enum.map(fn id ->
      %{id: id, branch_entry: Map.fetch!(current, id), main_entry: Map.fetch!(origin, id)}
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Renders the `Mix.raise/1` message: one block per colliding id (design
  section 3.3), never one raise per id.
  """
  @spec render_failure([collision()]) :: String.t()
  def render_failure(collisions) do
    header = "REQ-ID COLLISION DETECTED\n"

    bodies =
      Enum.map_join(collisions, "\n", fn %{id: id, branch_entry: b, main_entry: m} ->
        """
          #{id} is defined both on this branch and on origin/main, with different content.

          This branch's entry (#{@requirements_file}, line #{b.line}):
        #{indent(b.text)}

          origin/main's entry (already merged, line #{m.line}):
        #{indent(m.text)}

          This is the exact read-then-write race documented in
          docs/agents/protocols/ISSUE_QUEUE.md's "Updated 2026-08-21" section for
          ISS-NNNN ids, now caught for REQ-NNN ids too (ISS-0613). Do not edit around
          this -- pick the next REQ- id genuinely free on origin/main, renumber this
          branch's entry (and its `depends_on`/cross-references, and the matching
          queue registration's title if already registered), and re-run this check.
        """
      end)

    footer =
      "#{length(collisions)} collision(s) found -- fix and re-run " <>
        "`mix letflow.check_req_id_collision`."

    header <> "\n" <> bodies <> "\n" <> footer
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  # -- git shelling -----------------------------------------------------------

  @doc """
  Resolves the merge-base and origin/main snapshots of `docs/requirements.yaml`
  via `System.cmd/3` (mirroring `letflow.lint_handoffs`'s existing git-shelling
  precedent). Returns `{:skip, reason}`, never raising, when either the merge
  base or `origin/main` cannot be resolved -- the local "never fetched"
  tolerance from design section 4.
  """
  @spec resolve_git_snapshots() :: {:ok, String.t(), String.t()} | {:skip, String.t()}
  def resolve_git_snapshots do
    with {:ok, merge_base_sha} <- merge_base("origin/main", "HEAD"),
         {:ok, merge_base_content} <- show(merge_base_sha, @requirements_file),
         {:ok, origin_content} <- show("origin/main", @requirements_file) do
      {:ok, merge_base_content, origin_content}
    end
  end

  @spec merge_base(String.t(), String.t()) :: {:ok, String.t()} | {:skip, String.t()}
  defp merge_base(ref_a, ref_b) do
    case System.cmd("git", ["merge-base", ref_a, ref_b], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _status} -> {:skip, "`git merge-base #{ref_a} #{ref_b}` failed: #{String.trim(out)}"}
    end
  end

  @spec show(String.t(), String.t()) :: {:ok, String.t()} | {:skip, String.t()}
  defp show(ref, path) do
    case System.cmd("git", ["show", "#{ref}:#{path}"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _status} -> {:skip, "`git show #{ref}:#{path}` failed: #{String.trim(out)}"}
    end
  end

  # -- helpers ------------------------------------------------------------

  @spec split_entries([{pos_integer(), String.t()}]) :: [[{pos_integer(), String.t()}]]
  defp split_entries(section) do
    section
    |> Enum.reduce([], fn {_n, line} = pair, acc ->
      cond do
        Regex.match?(@entry_start_re, line) -> [[pair] | acc]
        acc == [] -> acc
        true -> [[pair | hd(acc)] | tl(acc)]
      end
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map(&Enum.filter(&1, fn {_n, line} -> attributed_or_start?(line) end))
  end

  # An entry's captured text keeps the `- id:` start line plus every
  # attributed (>= 4-space indent) field line -- same attribution rule
  # `check_requirements_registration` uses -- so a 2-space prose block note
  # between entries never gets swept into either neighbour's text.
  defp attributed_or_start?(line) do
    Regex.match?(@entry_start_re, line) or Regex.match?(@attributed_re, line)
  end

  @spec extract_id(String.t()) :: String.t()
  defp extract_id(id_line) do
    case Regex.run(@id_line_re, id_line) do
      [_, id] -> id
      nil -> String.trim(id_line)
    end
  end
end
