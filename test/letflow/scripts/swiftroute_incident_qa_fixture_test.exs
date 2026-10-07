defmodule Letflow.Scripts.SwiftrouteIncidentQaFixtureTest do
  @moduledoc """
  ISS-1022 / Q-1004 (GH #2294) -- the QA deployment payload for the SwiftRoute "Driver Incident
  Report" process (`test/fixtures/qa/swiftroute_incident_process_definition.json`, deployed by
  `scripts/seed_swiftroute_incident_definition.sh`) must stay in step with its simulation copy
  (`test/fixtures/simulation/swiftroute/process_shipment_dispatch.yaml`; the filename is
  historical) and with the alias sidecar the UAT preflight resolves.

  Why the in-step guard: the D-ESC escalation work (ISS-1007 / Q-989) lives on the human-task
  nodes, the timer node, the completion edges (`condition: "true"`) and the timeout edges. If the
  JSON drifted from the YAML, the QA instance would run a different escalation than the engine
  tests prove. SERVICE_TASK `attributes` are deliberately NOT compared: the YAML carries the
  simulation's relative stub endpoints, the QA JSON the dispatchable https ones
  (ISS-0930; see `qa_fixture_service_task_endpoints_test.exs`).

  Scrutiny and variable_schemas are covered table-driven elsewhere
  (`shipped_definitions_default_edge_scrutiny_test.exs`, `shipped_definitions_variable_schemas_test.exs`,
  `swiftroute_d_esc_escalation_fixture_test.exs`), all of which discover this fixture by glob/list.
  Pure file I/O, `async: true`.

  The accountant actor that `finance-estimate` routes to is seeded under ISS-1011 / Q-993, not here.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @root Path.expand("../../..", __DIR__)
  @json Path.join(@root, "test/fixtures/qa/swiftroute_incident_process_definition.json")
  @yaml Path.join(@root, "test/fixtures/simulation/swiftroute/process_shipment_dispatch.yaml")
  @alias_file Path.join(
                @root,
                "test/fixtures/uat/process-definition-aliases/proc-swiftroute-driver-incident.yaml"
              )
  @script Path.join(@root, "scripts/seed_swiftroute_incident_definition.sh")

  @escalation_nodes ~w(ops-assessment escalate-ops-assessment-to-ceo finance-estimate
                       escalate-finance-estimate-to-ceo ops-escalation-timer)
  @notice_nodes ~w(ops-auto-close finance-auto-close)

  defp json, do: @json |> File.read!() |> Jason.decode!()
  defp yaml, do: YamlElixir.read_from_file!(@yaml)

  defp node(d, id), do: Enum.find(d["graph"]["nodes"], &(&1["id"] == id))

  defp edge_shape(e),
    do: {e["id"], e["source"], e["target"], e["condition"], e["is_default"] == true}

  test "the QA fixture is Driver Incident Report v1.0 and matches the simulation copy and alias" do
    j = json()
    y = yaml()
    {:ok, a} = YamlElixir.read_from_file(@alias_file)

    assert j["name"] == "Driver Incident Report"
    assert j["version"] == "1.0"
    assert j["name"] == y["name"]
    assert j["version"] == y["version"]
    assert j["name"] == a["definition_name"], "preflight resolves the alias by this exact name"
  end

  test "node ids, node types and edge shapes are identical to the simulation graph" do
    j = json()
    y = yaml()

    assert Enum.map(j["graph"]["nodes"], &{&1["id"], &1["node_type"]}) |> Enum.sort() ==
             Enum.map(y["graph"]["nodes"], &{&1["id"], &1["node_type"]}) |> Enum.sort()

    assert Enum.map(j["graph"]["edges"], &edge_shape/1) |> Enum.sort() ==
             Enum.map(y["graph"]["edges"], &edge_shape/1) |> Enum.sort()
  end

  test "the D-ESC escalation nodes carry exactly the simulation's roles, timers and pairs" do
    j = json()
    y = yaml()

    for id <- @escalation_nodes do
      assert node(j, id)["attributes"] == node(y, id)["attributes"],
             "#{id}: QA JSON attributes drifted from the simulation YAML"
    end

    # spot-pin the ruling itself so a simultaneous edit of both files is also caught
    ops = node(j, "ops-assessment")["attributes"]

    assert {ops["role"], ops["escalation_timer_duration"], ops["escalation_role"]} ==
             {"role-ops-manager", "P1D", "role-ceo"}

    fin = node(j, "finance-estimate")["attributes"]

    assert {fin["role"], fin["escalation_timer_duration"], fin["escalation_role"]} ==
             {"role-accountant", "P1D", "role-ceo"}
  end

  test "the fail-closed notice nodes exist as SERVICE_TASKs, and completion edges carry the true condition (timer-fire safe)" do
    j = json()

    for id <- @notice_nodes, do: assert(node(j, id)["node_type"] == "SERVICE_TASK")

    for id <- ~w(e6 e8 e6-escalated e8-escalated) do
      e = Enum.find(j["graph"]["edges"], &(&1["id"] == id))
      assert e["condition"] == "true", "#{id} must stay the conditioned completion edge"
    end
  end

  test "the injury gate defaults toward more scrutiny (the safety notification)" do
    j = json()
    default = Enum.find(j["graph"]["edges"], &(&1["id"] == "injury-check-default"))
    assert default["is_default"] == true
    assert default["target"] == "safety-notification"
  end

  test "variable_schemas declare the condition variable as a boolean" do
    schemas = Map.new(json()["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})
    assert schemas["injury_involved"]["type"] == "boolean"
  end

  describe "seed script" do
    test "exists, targets this fixture and the Driver Incident Report name, sends via stdin" do
      src = File.read!(@script)

      assert src =~ "swiftroute_incident_process_definition.json"
      assert src =~ "Driver+Incident+Report"
      assert src =~ "--data-binary @-"
      refute src =~ ~r/-d\s+"\$\{PAYLOAD\}"/
      assert src =~ "proc-swiftroute-driver-incident"
      assert src =~ "ISS-1011"
    end

    test "prints no secret: the token is only ever used inside the Authorization header" do
      lines =
        @script
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))

      leaks =
        Enum.filter(lines, fn l ->
          l =~ ~r/(?<!\\)\$\{?QA_AUTH_TOKEN/ and l =~ ~r/\b(echo|printf)\b/
        end)

      assert leaks == [], inspect(leaks)
    end
  end
end
