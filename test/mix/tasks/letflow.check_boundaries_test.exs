defmodule Mix.Tasks.Letflow.CheckBoundariesTest do
  @moduledoc """
  Unit tests for `Mix.Tasks.Letflow.CheckBoundaries` — pure function tests for
  `classify_edge/2` and `parse_xref_output/1`, no DB or I/O required.

  REQ-405, WF02-REQ405-20260925. Design:
  `lib/letflow/design/req405-check-boundaries.md` §5.2.

  All tests are `async: true` — no shared state, no side effects.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.CheckBoundaries, as: CB

  # ================================================================
  # classify_edge/2 — AC1 unit tests (one per case from design §2.3)
  # ================================================================

  describe "classify_edge/2" do
    test "VIOLATION: core file outside modules imports module-subdir file" do
      # Rule 5: source outside all module subdirs, target inside one
      edge = {"lib/letflow/routers/x.ex", "lib/letflow/modules/m/y.ex"}
      assert {:violation, _} = CB.classify_edge(edge, %{})
    end

    test "OK: catalog.ex is the sanctioned importer" do
      # Rule 1: catalog.ex is explicitly permitted to reference module-subdir files
      edge = {"lib/letflow/modules/catalog.ex", "lib/letflow/modules/m/m.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "OK: core mechanism file references another core mechanism file" do
      # Rule 0: target (catalog.ex) is NOT in a module subdir — one level, no subdir
      # lib/letflow/modules/catalog.ex → path_in_module_subdir? returns false
      edge = {"lib/letflow/modules/installs.ex", "lib/letflow/modules/catalog.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "VIOLATION: cross-module ref when target not in depends_on" do
      # Rule 4: b not in a's depends_on
      edge = {"lib/letflow/modules/a/x.ex", "lib/letflow/modules/b/y.ex"}
      assert {:violation, _} = CB.classify_edge(edge, %{"a" => []})
    end

    test "OK: cross-module ref when target is in depends_on" do
      # Rule 3: authorized cross-module
      edge = {"lib/letflow/modules/a/x.ex", "lib/letflow/modules/b/y.ex"}
      assert :ok = CB.classify_edge(edge, %{"a" => ["b"]})
    end

    test "OK: test/support source is excluded from scope" do
      # Scope gate: test/support/ sources are excluded
      edge = {"test/support/z.ex", "lib/letflow/modules/m/y.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "OK: intra-module reference (same module subdir)" do
      # Rule 2: same module, always OK
      edge = {"lib/letflow/modules/a/x.ex", "lib/letflow/modules/a/y.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "OK: source outside lib/ is out of scope" do
      # Scope gate: source not under lib/
      edge = {"_build/dev/lib/letflow/ebin/foo.beam", "lib/letflow/modules/m/y.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "violation reason names both module ids (Rule 4)" do
      edge = {"lib/letflow/modules/alpha/x.ex", "lib/letflow/modules/beta/y.ex"}
      {:violation, reason} = CB.classify_edge(edge, %{"alpha" => []})
      assert reason =~ "alpha"
      assert reason =~ "beta"
      assert reason =~ "depends_on"
    end

    test "violation reason names source and target (Rule 5)" do
      edge = {"lib/letflow/router.ex", "lib/letflow/modules/exam/session.ex"}
      {:violation, reason} = CB.classify_edge(edge, %{})
      assert reason =~ "lib/letflow/router.ex"
      assert reason =~ "lib/letflow/modules/exam/session.ex"
      assert reason =~ "catalog.ex"
    end
  end

  # ================================================================
  # parse_xref_output/1
  # ================================================================

  describe "parse_xref_output/1" do
    test "blank input returns empty list" do
      assert CB.parse_xref_output("") == []
      assert CB.parse_xref_output("   \n   \n") == []
    end

    test "non-indented source with one target (backtick prefix) produces one edge pair" do
      input = "lib/a.ex\n`-- lib/b.ex\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "non-indented source with one target (pipe prefix) produces one edge pair" do
      input = "lib/a.ex\n|-- lib/b.ex\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "also handles plain-indented targets (space prefix) for compatibility" do
      input = "lib/a.ex\n  lib/b.ex\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "strips compile annotation from target paths" do
      input = "lib/a.ex\n`-- lib/b.ex (compile)\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "strips runtime annotation from target paths" do
      input = "lib/a.ex\n`-- lib/b.ex (runtime)\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "source with no dependencies produces no edges" do
      input = "lib/a.ex\nlib/b.ex\n"
      assert CB.parse_xref_output(input) == []
    end

    test "multiple sources and targets" do
      input = "lib/a.ex\n|-- lib/b.ex\n`-- lib/c.ex\nlib/d.ex\n`-- lib/e.ex\n"

      result = CB.parse_xref_output(input)
      assert length(result) == 3
      assert {"lib/a.ex", "lib/b.ex"} in result
      assert {"lib/a.ex", "lib/c.ex"} in result
      assert {"lib/d.ex", "lib/e.ex"} in result
    end

    test "target before any source is skipped gracefully" do
      # Defensive — should never occur in real xref output
      input = "`-- lib/orphan.ex\nlib/a.ex\n`-- lib/b.ex\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end
  end

  # ================================================================
  # build_depends_on_map/1
  # ================================================================

  describe "build_depends_on_map/1" do
    test "empty manifest list → empty map" do
      assert CB.build_depends_on_map([]) == %{}
    end

    test "maps manifest id to its depends_on list" do
      manifests = [
        %{id: "a", depends_on: ["b", "c"], version: "1.0", pack: nil,
          permissions: [], role_grants: %{}, required_roles: [],
          settings_schema: nil, route_policies: []},
        %{id: "b", depends_on: [], version: "1.0", pack: nil,
          permissions: [], role_grants: %{}, required_roles: [],
          settings_schema: nil, route_policies: []}
      ]

      result = CB.build_depends_on_map(manifests)
      assert result == %{"a" => ["b", "c"], "b" => []}
    end
  end
end

defmodule Mix.Tasks.Letflow.CheckBoundariesTaskTest do
  @moduledoc """
  System-level tests for `mix letflow.check_boundaries` — invoked via
  `System.cmd/3`, confirming real end-to-end behaviour.

  These tests are `async: false` because they shell out to `mix` and
  depend on the compiled project tree.

  REQ-405, WF02-REQ405-20260925. Design:
  `lib/letflow/design/req405-check-boundaries.md` §5.3, §5.5.
  """

  use ExUnit.Case, async: false

  @project_root Path.expand("../../..", __DIR__)

  # ================================================================
  # AC2 — system invocation, exits 0 on clean tree
  # ================================================================

  describe "system invocation (AC2)" do
    test "exits 0 on the current branch tree (AC2)" do
      {output, exit_code} =
        System.cmd("mix", ["letflow.check_boundaries"],
          cd: @project_root,
          stderr_to_stdout: true
        )

      assert exit_code == 0, "expected exit 0; got #{exit_code}. Output:\n#{output}"
      assert output =~ "OK"
    end
  end

  # ================================================================
  # AC4 — alias wiring
  # ================================================================

  describe "the letflow.check alias wiring (AC4)" do
    setup do
      aliases = Mix.Project.config()[:aliases][:"letflow.check"]
      at = &Enum.find_index(aliases, fn step -> step == &1 end)
      %{aliases: aliases, at: at}
    end

    # T-ALIAS-WIRED
    test "T-ALIAS-WIRED -- letflow.check_boundaries is a step of `mix letflow.check`",
         %{aliases: aliases} do
      assert "letflow.check_boundaries" in aliases
    end

    # T-ALIAS-SLOT
    test "T-ALIAS-SLOT -- runs after compile --warnings-as-errors and before letflow.check.test",
         %{at: at} do
      assert at.("compile --warnings-as-errors") < at.("letflow.check_boundaries"),
             "expected `compile --warnings-as-errors` to come before `letflow.check_boundaries`"

      assert at.("letflow.check_boundaries") < at.("letflow.check.test"),
             "expected `letflow.check_boundaries` to come before `letflow.check.test`"
    end
  end
end
