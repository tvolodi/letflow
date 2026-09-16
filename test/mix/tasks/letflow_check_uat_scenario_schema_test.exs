defmodule Mix.Tasks.Letflow.CheckUatScenarioSchemaTest do
  @moduledoc """
  Coverage for REQ-358 -- `mix letflow.check_uat_scenario_schema`
  (`lib/mix/tasks/letflow.check_uat_scenario_schema.ex`).

  Spec: `test/specs/REQ-358.md`. Design:
  `lib/letflow/design/req358-uat-scope-branching-env.md` §2 (mechanical rules
  SCHEMA-1..6), §1.2 (the `scope`/`company_id` default-derivation rule) and §3
  (the login-routing throwaway fixture). Run: `WF02-REQ358-20260916`, WF-02
  Step 3.

  This is a WF-02 (new-code) requirement, not a WF-03 regression, so the
  fail-first-against-pre-fix-code discipline does not apply here -- the
  module under test is genuinely new and there is no prior "broken" version
  to run these tests against. Instead, every fixture below is built so that a
  concrete, plausible bug in `check_scenario/2` would turn it red; each test
  says which SCHEMA rule it pins and, where useful, names the specific
  mistake it would catch (e.g. "an implementation that only checks
  `scope:` and never falls back to `company_id:`" for the backward-compat
  fixtures).

  ## What this suite intentionally does NOT test

  `check_scenario/2` and `check_file/1` are exhaustively covered here. The
  module has **no branch-evaluation/branch-matching function** -- confirmed
  by reading `lib/mix/tasks/letflow.check_uat_scenario_schema.ex` in full:
  its only exported functions are `run/1`, `check_file/1`, `check_scenario/2`
  and `render/1`, none of which pick a branch or evaluate a `when:` condition
  against an observed fact. Branch *evaluation* (which of
  `platform_admin_dashboard` / `tenant_user_dashboard` /
  `unauthenticated_fallback` actually runs for a given session) is
  UAT-RUNNER's own runtime job against a live role/session, per
  `.claude/agents/uat-runner.md`'s "Evaluating a `when:` branch" section (design
  §4.3) -- it is a Claude subagent reading procedural markdown against a real
  HTTP session, not an Elixir function, and is not unit-testable here. This
  suite proves AC4's *schema* half only: the login-routing fixture's
  three-branch shape is valid under SCHEMA-1..6. The runtime-evaluation half
  is exercised by a real UAT-RUNNER run against QA, dispatched separately
  (not this step's job -- see the REQ-358 task description).
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.CheckUatScenarioSchema, as: Check

  @project_root Path.expand("../../..", __DIR__)
  @meridian_file Path.join(
                   @project_root,
                   "test/fixtures/uat/scenarios/meridian/loan-origination-below-threshold.yaml"
                 )
  @platform_file Path.join(
                   @project_root,
                   "test/fixtures/uat/scenarios/platform/definition-promotion-approved.yaml"
                 )
  @login_routing_file Path.join(
                        @project_root,
                        "test/fixtures/uat/scenarios/_throwaway/login-routing-example.yaml"
                      )

  # ------------------------------------------------------------------
  # Fixture construction. Plain Elixir maps with string keys, matching
  # YamlElixir.read_from_file/1's own output shape (the codebase's existing
  # convention -- see test/support/simulation/scenario_fixture.ex) so
  # check_scenario/2 is exercised exactly as run/1 would call it, without
  # going through the filesystem for every case.
  # ------------------------------------------------------------------

  @fixture_path "fixture.yaml"

  defp flat_step,
    do: %{"step" => 1, "actor" => "viewer", "action" => "does a thing", "via" => "gui"}

  defp flat_outcome, do: %{"id" => "EO-001", "description" => "something is observed"}

  # A minimal, otherwise-fully-valid flat (non-branching) scenario. Callers
  # override only the keys under test so each fixture stays legible about
  # what it is actually pinning.
  defp valid_flat(overrides) do
    %{
      "id" => "REQ-358-fixture",
      "title" => "A valid flat scenario",
      "version" => "1.0",
      "scope" => "lending",
      "steps" => [flat_step()],
      "expected_outcomes" => [flat_outcome()]
    }
    |> Map.merge(overrides)
  end

  defp branch(name, when_clause) do
    %{
      "name" => name,
      "when" => when_clause,
      "steps" => [flat_step()],
      "expected_outcomes" => [flat_outcome()]
    }
  end

  # A minimal, otherwise-fully-valid branching scenario built from the given
  # branch list.
  defp valid_branching(branches) do
    %{
      "id" => "REQ-358-fixture",
      "title" => "A valid branching scenario",
      "version" => "1.0",
      "scope" => "platform",
      "branches" => branches
    }
  end

  defp rules(violations), do: violations |> Enum.map(& &1.rule) |> Enum.uniq() |> Enum.sort()

  defp check(data), do: Check.check_scenario(@fixture_path, data)

  # ==================================================================
  # AC1 -- backward compatibility (design §1.2's default-derivation rule)
  # ==================================================================

  describe "AC1 -- backward compatibility" do
    test "F-SCOPE-FROM-COMPANY-ID -- no scope:, only company_id:, resolves and passes" do
      # No `scope:` key at all -- exactly the shape of all 29 pre-existing
      # scenario files. An implementation that requires an explicit `scope:`
      # key (never falling back to `company_id:`) would flag SCHEMA-3 here;
      # this fixture is what makes that mistake visible.
      data =
        valid_flat(%{})
        |> Map.delete("scope")
        |> Map.put("company_id", "meridian")

      violations = check(data)

      assert violations == [],
             "an existing tenant-scenario shape (company_id, no scope) must validate " <>
               "unchanged -- got #{inspect(violations)}"
    end

    test "F-SCOPE-FROM-COMPANY-ID-PLATFORM -- company_id: platform resolves too" do
      data = valid_flat(%{}) |> Map.delete("scope") |> Map.put("company_id", "platform")

      assert check(data) == []
    end

    test "F-SCOPE-EXPLICIT-NO-COMPANY-ID -- an explicit scope: with no company_id: is fine" do
      # The forward-looking case design §1.2 also describes: a genuinely new
      # Letflow-native scenario with no legacy company binding at all.
      data = valid_flat(%{"scope" => "lending"}) |> Map.delete("company_id")

      assert check(data) == []
    end

    test "T-LIVE-MERIDIAN -- the real, unedited meridian fixture validates via check_file/1" do
      # AC1's own evidence mechanism per design §5: run against the real,
      # untouched file (no scope: key, only company_id: meridian) and see a
      # clean OK. Uses check_file/1 (not check_scenario/2) so the real
      # YAML-parsing path is exercised too, not just the pure core.
      assert File.exists?(@meridian_file), "fixture corpus must contain the meridian file"

      result = Check.check_file(@meridian_file)

      assert result.ok? == true

      assert result.violations == [],
             "the untouched meridian file must pass with zero edits -- got " <>
               inspect(result.violations)
    end

    test "T-LIVE-PLATFORM -- the real, unedited platform fixture validates via check_file/1" do
      assert File.exists?(@platform_file), "fixture corpus must contain the platform file"

      result = Check.check_file(@platform_file)

      assert result.ok? == true
      assert result.violations == []
    end
  end

  # ==================================================================
  # AC2 -- malformed scope/branching fixtures are rejected with a specific,
  # checkable error (one test case per SCHEMA-3..6 rule named in the design)
  # ==================================================================

  describe "AC2 -- malformed rejection" do
    test "F-SCOPE-MISSING -- neither scope: nor company_id: is SCHEMA-3" do
      data = valid_flat(%{}) |> Map.delete("scope")

      violations = check(data)

      assert rules(violations) == ["SCHEMA-3"]
      assert Enum.any?(violations, &(&1.message =~ "neither `scope:` nor `company_id:`"))
    end

    test "F-SCOPE-EMPTY-STRING -- scope: \"\" does not silently pass SCHEMA-3" do
      # A common malformed shape: the key is present but its value is the
      # empty string. A check that only tests Map.has_key?/2 (never
      # non-emptiness) would let this through; this fixture catches that.
      data = valid_flat(%{"scope" => ""}) |> Map.delete("company_id")

      assert rules(check(data)) == ["SCHEMA-3"]
    end

    test "F-SCOPE-WRONG-TYPE -- a non-string scope: is SCHEMA-3, not coerced" do
      data = valid_flat(%{"scope" => 42}) |> Map.delete("company_id")

      assert rules(check(data)) == ["SCHEMA-3"]
    end

    test "F-REQUIRED-FIELDS-MISSING -- missing id/title/version is SCHEMA-2, one per field" do
      data = %{
        "scope" => "lending",
        "steps" => [flat_step()],
        "expected_outcomes" => [flat_outcome()]
      }

      violations = check(data)

      assert rules(violations) == ["SCHEMA-2"]
      assert length(violations) == 3, "id, title AND version must each be flagged individually"
    end

    test "F-BOTH-STEPS-AND-BRANCHES -- carrying both step shapes at once is SCHEMA-4" do
      data =
        valid_flat(%{})
        |> Map.put("branches", [
          branch("only_branch", %{"fact" => "role", "op" => "eq", "value" => "PLATFORM_ADMIN"})
        ])

      violations = check(data)

      assert rules(violations) == ["SCHEMA-4"]
      assert Enum.any?(violations, &(&1.message =~ "must use exactly one of the two step shapes"))
    end

    test "F-NEITHER-STEPS-NOR-BRANCHES -- carrying neither step shape is SCHEMA-4" do
      data = valid_flat(%{}) |> Map.delete("steps") |> Map.delete("expected_outcomes")

      violations = check(data)

      assert rules(violations) == ["SCHEMA-4"]
      assert Enum.any?(violations, &(&1.message =~ "must define at least one step shape"))
    end

    test "F-BRANCHES-EMPTY-LIST -- branches: [] is SCHEMA-5" do
      data = valid_branching([])

      assert rules(check(data)) == ["SCHEMA-5"]
    end

    test "F-BRANCH-BAD-OP -- an operator outside eq/in is SCHEMA-5, not silently allowed" do
      # This is the guardrail the design is explicit about: the `when:`
      # vocabulary is deliberately narrow (eq/in/else only, never and/or/not
      # or a relational operator). An implementation that accepts any string
      # op (or only rejects a hardcoded blocklist) would let "gt" through.
      data =
        valid_branching([
          branch("bad_op", %{"fact" => "role", "op" => "gt", "value" => "PLATFORM_ADMIN"})
        ])

      violations = check(data)

      assert rules(violations) == ["SCHEMA-5"]
      assert Enum.any?(violations, &(&1.message =~ "only `eq` and `in` are allowed"))
    end

    test "F-BRANCH-EQ-WITH-LIST-VALUE -- op: eq with a list value is SCHEMA-5" do
      data =
        valid_branching([
          branch("wrong_value_shape", %{"fact" => "role", "op" => "eq", "value" => ["A", "B"]})
        ])

      assert rules(check(data)) == ["SCHEMA-5"]
    end

    test "F-BRANCH-IN-WITH-EMPTY-LIST -- op: in with an empty value list is SCHEMA-5" do
      data =
        valid_branching([
          branch("empty_in_list", %{"fact" => "role", "op" => "in", "value" => []})
        ])

      assert rules(check(data)) == ["SCHEMA-5"]
    end

    test "F-BRANCH-MISSING-NAME -- a branch with no name is SCHEMA-5" do
      bad_branch =
        %{"fact" => "role", "op" => "eq", "value" => "PLATFORM_ADMIN"}
        |> then(
          &%{"when" => &1, "steps" => [flat_step()], "expected_outcomes" => [flat_outcome()]}
        )

      violations = check(valid_branching([bad_branch]))

      assert rules(violations) == ["SCHEMA-5"]
      assert Enum.any?(violations, &(&1.message =~ "missing or empty `name`"))
    end

    test "F-BRANCH-DUPLICATE-NAME -- two branches sharing a name is SCHEMA-5" do
      data =
        valid_branching([
          branch("same_name", %{"fact" => "role", "op" => "eq", "value" => "PLATFORM_ADMIN"}),
          branch("same_name", %{"fact" => "role", "op" => "eq", "value" => "TENANT_ADMIN"})
        ])

      violations = check(data)

      assert "SCHEMA-5" in rules(violations)
      assert Enum.any?(violations, &(&1.message =~ "not unique within the file"))
    end

    test "F-BRANCH-EMPTY-STEPS -- a branch with an empty steps: list is SCHEMA-5" do
      bad_branch = %{
        "name" => "empty_steps",
        "when" => %{"fact" => "role", "op" => "eq", "value" => "X"},
        "steps" => [],
        "expected_outcomes" => [flat_outcome()]
      }

      violations = check(valid_branching([bad_branch]))

      assert rules(violations) == ["SCHEMA-5"]
      assert Enum.any?(violations, &(&1.message =~ "missing or empty `steps:` list"))
    end

    test "F-ELSE-NOT-LAST -- an else branch that is not the final entry is SCHEMA-6" do
      data =
        valid_branching([
          branch("fallback", "else"),
          branch("tenant_user_dashboard", %{
            "fact" => "role",
            "op" => "in",
            "value" => ["TENANT_ADMIN"]
          })
        ])

      violations = check(data)

      assert rules(violations) == ["SCHEMA-6"]
      assert Enum.any?(violations, &(&1.message =~ "is not the last entry"))
    end

    test "F-ELSE-MULTIPLE -- two else branches in one file is SCHEMA-6" do
      data =
        valid_branching([
          branch("fallback_one", "else"),
          branch("fallback_two", "else")
        ])

      violations = check(data)

      assert rules(violations) == ["SCHEMA-6"]
      assert Enum.any?(violations, &(&1.message =~ "at most one is allowed"))
    end

    test "F-PARSE-ERROR -- a file that is not valid YAML is rejected via check_file/1, SCHEMA-1" do
      dir = Path.join(System.tmp_dir!(), "letflow-cuss-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "broken.yaml")
      # An unterminated flow-mapping: guaranteed to fail YAML parsing rather
      # than parsing into something merely wrong-shaped.
      File.write!(path, "id: [this is not closed\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      result = Check.check_file(path)

      assert result.ok? == false
      assert [violation] = result.violations
      assert violation.rule == "SCHEMA-1"
      assert violation.message =~ "YAML parse error"
    end

    test "F-NOT-A-MAPPING -- a file whose top level is a list, not a map, is SCHEMA-1" do
      dir = Path.join(System.tmp_dir!(), "letflow-cuss-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "list.yaml")
      File.write!(path, "- one\n- two\n")
      on_exit(fn -> File.rm_rf!(dir) end)

      result = Check.check_file(path)

      assert result.ok? == false
      assert [violation] = result.violations
      assert violation.rule == "SCHEMA-1"
      assert violation.message =~ "not a mapping"
    end
  end

  # ==================================================================
  # AC4 -- branching sufficiency (schema-validation half; see moduledoc for
  # why UAT-RUNNER's own runtime branch evaluation is not covered here)
  # ==================================================================

  describe "AC4 -- branching sufficiency (schema half)" do
    test "T-LOGIN-ROUTING-FIXTURE-VALID -- the three-branch login-routing fixture validates" do
      # Proves the eq/in/else vocabulary is SCHEMA-1..6-valid for exactly the
      # role=PLATFORM_ADMIN / role=<tenant-role> / unauthenticated (else)
      # shape the requirement text names -- design §3's throwaway fixture.
      assert File.exists?(@login_routing_file),
             "the throwaway login-routing fixture must exist for this AC4 check"

      result = Check.check_file(@login_routing_file)

      assert result.ok? == true

      assert result.violations == [],
             "the login-routing fixture must be schema-valid -- got #{inspect(result.violations)}"
    end

    test "F-LOGIN-ROUTING-SHAPE-HERMETIC -- the same three-branch shape, built in-suite" do
      # A hermetic counterpart to T-LOGIN-ROUTING-FIXTURE-VALID: the exact
      # branch shape named in the requirement text (PLATFORM_ADMIN / a
      # tenant-role list / else), built as an in-suite fixture rather than
      # read from disk, so this property does not depend on that file's
      # continued existence at its current path.
      data =
        valid_branching([
          branch("platform_admin_dashboard", %{
            "fact" => "role",
            "op" => "eq",
            "value" => "PLATFORM_ADMIN"
          }),
          branch("tenant_user_dashboard", %{
            "fact" => "role",
            "op" => "in",
            "value" => ["TENANT_ADMIN", "TENANT_USER"]
          }),
          branch("unauthenticated_fallback", "else")
        ])

      assert check(data) == []
    end
  end

  describe "F-TOTALITY -- ok? agrees with the violations list, for every fixture above" do
    test "check_file/1's ok? is true iff violations is empty" do
      for path <- [@meridian_file, @platform_file, @login_routing_file] do
        result = Check.check_file(path)
        assert result.ok? == (result.violations == []), path
      end
    end
  end
end
