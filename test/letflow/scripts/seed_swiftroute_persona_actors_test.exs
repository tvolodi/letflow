defmodule Letflow.Scripts.SeedSwiftroutePersonaActorsTest do
  @moduledoc """
  ISS-0761 regression guard: structural assertions on
  `scripts/seed_swiftroute_persona_actors.sh` and `.claude/agents/uat-runner.md`.

  These tests verify:
    * Lena is NOT added to role-ops-manager or role-ceo (TC-0761-01)
    * Marco IS associated with role-ops-manager (TC-0761-02)
    * Alice IS associated with role-ceo (TC-0761-03)
    * Part A prerequisite guard is present in the script (TC-0761-04)
    * uat-runner.md references the persona actor provisioning script (TC-0761-05)

  All assertions are source-level (File.read! only) — no database, no HTTP,
  no process state — so `async: true` is safe.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @script_path Path.expand("../../../scripts/seed_swiftroute_persona_actors.sh", __DIR__)
  @uat_runner_path Path.expand("../../../.claude/agents/uat-runner.md", __DIR__)

  setup_all do
    script = File.read!(@script_path)
    uat_runner = File.read!(@uat_runner_path)
    %{script: script, uat_runner: uat_runner}
  end

  # ---------------------------------------------------------------------------
  # TC-0761-01: Lena is NOT added to role-ops-manager or role-ceo
  # ---------------------------------------------------------------------------

  test "TC-0761-01: lena is not added to role-ops-manager or role-ceo", %{script: script} do
    # Split into lines so we can check lena-adjacent lines only
    lena_role_lines =
      script
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.contains?(line, "lena") and
          (String.contains?(line, "OPS_MGR_GROUP_ID") or
             String.contains?(line, "CEO_GROUP_ID") or
             String.contains?(line, "role-ops-manager") or
             String.contains?(line, "role-ceo"))
      end)

    assert lena_role_lines == [],
           "Expected lena NOT to be added to role-ops-manager or role-ceo, " <>
             "but found lines: #{inspect(lena_role_lines)}"
  end

  # ---------------------------------------------------------------------------
  # TC-0761-02: Marco IS associated with role-ops-manager
  # ---------------------------------------------------------------------------

  test "TC-0761-02: marco is added to role-ops-manager group", %{script: script} do
    assert String.contains?(script, ~s[add_group_member "${OPS_MGR_GROUP_ID}"     "${MARCO_ID}"]),
           "Expected script to add marco to OPS_MGR_GROUP_ID (role-ops-manager), but the call was not found"
  end

  # ---------------------------------------------------------------------------
  # TC-0761-03: Alice IS associated with role-ceo
  # ---------------------------------------------------------------------------

  test "TC-0761-03: alice is added to role-ceo group", %{script: script} do
    assert String.contains?(script, ~s[add_group_member "${CEO_GROUP_ID}"         "${ALICE_ID}"]),
           "Expected script to add alice to CEO_GROUP_ID (role-ceo), but the call was not found"
  end

  # ---------------------------------------------------------------------------
  # TC-0761-04: Part A prerequisite guard is present
  # ---------------------------------------------------------------------------

  test "TC-0761-04: script has Part A prerequisite guard referencing Keycloak", %{script: script} do
    has_keycloak_guard =
      String.contains?(script, "Part A") and
        (String.contains?(script, "Keycloak") or String.contains?(script, "keycloak"))

    assert has_keycloak_guard,
           "Expected script to contain a Part A prerequisite guard mentioning Keycloak, " <>
             "but neither 'Part A' + 'Keycloak' were both found"

    # Guard must cause an exit on missing user (not silently continue)
    assert String.contains?(script, "exit 1"),
           "Expected script to call 'exit 1' on Part A failure, but it was not found"
  end

  # ---------------------------------------------------------------------------
  # TC-0761-05: uat-runner.md references the persona actor provisioning script
  # ---------------------------------------------------------------------------

  test "TC-0761-05: uat-runner.md contains reference to seed_swiftroute_persona_actors",
       %{uat_runner: uat_runner} do
    assert String.contains?(uat_runner, "seed_swiftroute_persona_actors"),
           "Expected .claude/agents/uat-runner.md to reference 'seed_swiftroute_persona_actors', " <>
             "but it was not found — SwiftRoute credentials / provisioning section may be missing"
  end
end
