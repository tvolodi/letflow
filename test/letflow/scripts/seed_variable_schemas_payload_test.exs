defmodule Letflow.Scripts.SeedVariableSchemasPayloadTest do
  @moduledoc """
  ISS-1027 / Q-1009 (GH #2307) -- the QA seed scripts must deliver each fixture's `variable_schemas`
  to POST /definitions.

  The Meridian, Vortex and SwiftRoute seed scripts build their request body from the fixture file
  itself (`rewrite_service_task_base "$(cat <fixture>)"`, which rewrites SERVICE_TASK endpoints
  only), so the schemas travel iff (a) the fixture carries them (asserted in
  `ShippedDefinitionsVariableSchemasTest`), (b) every script feeds the fixture unmodified through
  that helper to `-d`, and (c) the helper keeps `variable_schemas` byte-for-byte. All three are
  asserted here, (c) by actually running the helper under bash + jq with a non-default mock base
  (the only path that rewrites the payload).

  Idempotency is unchanged and asserted by the existing seed tests: a fixture whose version is
  already ACTIVE is skipped, which is why ISS-1027 bumps the version of every fixture it touches.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @root Path.expand("../../..", __DIR__)

  # script => [{fixture, header label}]
  @scripts %{
    "scripts/seed_meridian_definition.sh" => [
      {"meridian_loan_origination_process_definition.json", "Loan Origination"},
      {"meridian_regulatory_compliance_review_process_definition.json",
       "Regulatory Compliance Review"}
    ],
    "scripts/seed_vortex_definition.sh" => [
      {"vortex_production_order_release_process_definition.json", "Production Order Release"},
      {"vortex_supplier_quality_deviation_process_definition.json", "Supplier Quality Deviation"},
      {"vortex_8d_corrective_action_definition.json", "8D Corrective Action"}
    ],
    "scripts/seed_swiftroute_definition.sh" => [
      {"swiftroute_process_definition.json", "Shipment Approval"}
    ]
  }

  defp read(rel), do: @root |> Path.join(rel) |> File.read!()
  defp fixture_path(file), do: Path.join("test/fixtures/qa", file)
  defp fixture(file), do: file |> fixture_path() |> read() |> Jason.decode!()

  for {script, fixtures} <- @scripts do
    describe "#{script}" do
      test "posts every fixture it seeds, unmodified apart from the endpoint-base rewrite" do
        src = read(unquote(script))

        for {file, _label} <- unquote(Macro.escape(fixtures)) do
          assert src =~ fixture_path(file), "#{unquote(script)} does not reference #{file}"
        end

        # The body of the POST is the fixture run through rewrite_service_task_base and nothing else.
        assert src =~
                 ~r/rewrite_service_task_base "\$\(cat "[^"]*(?:fixture_path|FIXTURE_PATH)[^"]*"\)"/

        assert src =~ ~r/-d "\$\{(?:payload|PAYLOAD)\}"/
      end

      test "never strips or overrides variable_schemas in the payload" do
        src = read(unquote(script))
        refute src =~ ~r/jq[^\n]*(?:del|delpaths|with_entries)[^\n]*variable_schemas/
      end

      test "header version of each unit matches its fixture version (a bump must reach the comment)" do
        src = read(unquote(script))

        for {file, label} <- unquote(Macro.escape(fixtures)) do
          version = fixture(file)["version"]

          assert src =~ ~r/"#{Regex.escape(label)}" v#{Regex.escape(version)}\b/,
                 "#{unquote(script)} header does not name #{label} v#{version}"
        end
      end
    end
  end

  describe "rewrite_service_task_base (scripts/lib/seed_service_task_base.sh) keeps variable_schemas" do
    test "every fixture's variable_schemas survive the helper byte-for-byte under a non-default mock base" do
      assert bash = System.find_executable("bash"), "bash is required to run the seed helper"
      assert System.find_executable("jq"), "jq is required by the seed scripts"

      for {_script, fixtures} <- @scripts, {file, _label} <- fixtures do
        input = fixture(file)

        {out, 0} =
          System.cmd(
            bash,
            [
              "-c",
              ~s|source scripts/lib/seed_service_task_base.sh && rewrite_service_task_base "$(cat #{fixture_path(file)})"|
            ],
            cd: @root,
            env: [{"SERVICE_TASK_MOCK_BASE_URL", "https://mock.example.test/echo"}],
            stderr_to_stdout: false
          )

        output = Jason.decode!(out)

        assert output["variable_schemas"] == input["variable_schemas"], file
        assert output["name"] == input["name"]
        assert output["version"] == input["version"]
        assert output["description"] == input["description"]

        # ...and the rewrite really ran on the endpoints it targets (the default
        # https://httpbin.org/anything prefix; other stub URLs are deliberately left alone), so
        # this test cannot pass vacuously.
        default = "https://httpbin.org/anything"

        endpoints = fn doc ->
          for n <- doc["graph"]["nodes"],
              n["node_type"] == "SERVICE_TASK",
              do: n["attributes"]["endpoint"]
        end

        targeted = Enum.count(endpoints.(input), &String.starts_with?(&1, default))

        rewritten =
          Enum.count(
            endpoints.(output),
            &String.starts_with?(&1, "https://mock.example.test/echo")
          )

        assert rewritten == targeted, file

        unless file == "vortex_8d_corrective_action_definition.json",
          do: assert(targeted > 0, "#{file}: no SERVICE_TASK endpoint exercised the rewrite")
      end
    end
  end
end
