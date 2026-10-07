defmodule Letflow.Scripts.QaFixtureServiceTaskEndpointsTest do
  @moduledoc """
  ISS-0930 regression: every SERVICE_TASK node in `test/fixtures/qa/*.json` (the literal
  payload the seed scripts POST) must be dispatchable by the real engine.

  Before the fix the seeded endpoints were `"POST /kyc/screen"`-style strings with no
  `method`, which `Letflow.Webhooks.UrlValidator` rejects (`scheme: nil`), so instances
  ERRORed with `request_build_error` at the first service task.

  The test reuses production code (`ServiceTask.parse_config_from_node_attributes/1` and
  `UrlValidator.validate/2` with an injected stub resolver). No DB, HTTP, DNS, or process
  state, so `async: true` is safe and no network is needed.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.ServiceTask
  alias Letflow.Webhooks.UrlValidator

  # ISS-0935 added non-ProcessDefinition fixtures to this same directory
  # (entity-type definitions and their sample-record import payloads,
  # named `vortex_production_batch_entity_definition.json`,
  # `vortex_shipment_manifest_entity_definition.json`,
  # `vortex_production_batch_records.json`,
  # `vortex_shipment_manifest_records.json`) -- this test's own scope
  # (ISS-0930) is SERVICE_TASK dispatch inside ProcessDefinition payloads
  # only, so the glob is narrowed to `*_process_definition.json` rather
  # than every JSON file in the directory.
  @fixture_glob Path.expand("../../fixtures/qa/*_process_definition.json", __DIR__)
  @scripts_dir Path.expand("../../../scripts", __DIR__)
  @seed_scripts ~w(seed_meridian_definition.sh seed_vortex_definition.sh seed_swiftroute_definition.sh seed_swiftroute_incident_definition.sh)
  @valid_methods ~w(GET POST PUT PATCH DELETE)
  @placeholder_regex ~r/\{\{\s*variables\.([a-zA-Z0-9_]+)\s*\}\}/
  @valid_placeholder_regex ~r/\{\{\s*variables\.[a-zA-Z0-9_]+\s*\}\}/

  @fixtures (for path <- Path.wildcard(@fixture_glob) |> Enum.sort() do
               nodes =
                 path
                 |> File.read!()
                 |> Jason.decode!()
                 |> get_in(["graph", "nodes"])
                 |> Enum.filter(&(&1["node_type"] == "SERVICE_TASK"))

               {Path.basename(path), nodes}
             end)

  defp fixture_nodes(file), do: Map.fetch!(Map.new(@fixtures), file)

  defp public_resolver(_host_charlist), do: {:ok, [{:inet, {93, 184, 216, 34}, []}]}

  defp build_node(json_node) do
    %Graph.Node{
      id: json_node["id"],
      node_type: :SERVICE_TASK,
      attributes: json_node["attributes"]
    }
  end

  defp render(template), do: Regex.replace(@placeholder_regex, template, "sample1")

  # Mirrors the production path: parse config -> render url_template -> SSRF gate.
  defp dispatch_gate(json_node) do
    with {:ok, config} <- ServiceTask.parse_config_from_node_attributes(build_node(json_node)) do
      UrlValidator.validate(render(config.url_template), &public_resolver/1)
    end
  end

  test "TC-0930-01: fixture set is non-empty and every fixture has >= 1 SERVICE_TASK node" do
    assert @fixtures != [], "no fixtures matched #{@fixture_glob}"

    for {file, nodes} <- @fixtures do
      assert nodes != [], "#{file} has no SERVICE_TASK nodes"
    end
  end

  for {file, _nodes} <- @fixtures do
    describe "#{file}" do
      test "TC-0930-02: endpoint is an https URL with a host" do
        nodes = fixture_nodes(unquote(file))

        for node <- nodes do
          endpoint = node["attributes"]["endpoint"]

          assert is_binary(endpoint), "node #{node["id"]}: endpoint not a binary"
          uri = URI.parse(endpoint)

          assert uri.scheme == "https",
                 "node #{node["id"]}: endpoint #{inspect(endpoint)} scheme is #{inspect(uri.scheme)}"

          assert is_binary(uri.host) and uri.host != "",
                 "node #{node["id"]}: endpoint #{inspect(endpoint)} has no host"
        end
      end

      test "TC-0930-03: explicit method attribute agrees with parsed Config.method" do
        nodes = fixture_nodes(unquote(file))

        for node <- nodes do
          method = node["attributes"]["method"]

          assert is_binary(method), "node #{node["id"]}: no explicit method attribute"

          assert String.upcase(method) in @valid_methods,
                 "node #{node["id"]}: invalid method #{inspect(method)}"

          {:ok, config} = ServiceTask.parse_config_from_node_attributes(build_node(node))

          assert String.to_existing_atom(String.upcase(method)) == config.method,
                 "node #{node["id"]}: parsed method #{inspect(config.method)} != #{inspect(method)}"
        end
      end

      test "TC-0930-04: parses as inline_url route (no service_id)" do
        nodes = fixture_nodes(unquote(file))

        for node <- nodes do
          assert {:ok, %ServiceTask.Config{route_kind: :inline_url}} =
                   ServiceTask.parse_config_from_node_attributes(build_node(node)),
                 "node #{node["id"]}: not an inline_url config"
        end
      end

      test "TC-0930-05: rendered endpoint passes UrlValidator (request_build_error gate)" do
        nodes = fixture_nodes(unquote(file))

        for node <- nodes do
          assert dispatch_gate(node) == :ok,
                 "node #{node["id"]}: #{inspect(node["attributes"]["endpoint"])} rejected by UrlValidator"
        end
      end

      test "TC-0930-06: no unrendered single-brace placeholder remains" do
        nodes = fixture_nodes(unquote(file))

        for node <- nodes do
          endpoint = node["attributes"]["endpoint"]
          stripped = Regex.replace(@valid_placeholder_regex, endpoint, "")

          refute String.contains?(stripped, ["{", "}"]),
                 "node #{node["id"]}: endpoint #{inspect(endpoint)} has a malformed placeholder"
        end
      end
    end
  end

  test "TC-0930-07: negative guard - the legacy 'POST /kyc/screen' shape is rejected by the gate" do
    legacy = %{"id" => "legacy", "attributes" => %{"endpoint" => "POST /kyc/screen"}}

    assert dispatch_gate(legacy) == {:error, :target_url_not_allowed}

    # and a well-formed https endpoint passes the same helper
    good = %{
      "id" => "good",
      "attributes" => %{
        "endpoint" => "https://httpbin.org/anything/a/{{variables.x}}/b",
        "method" => "POST"
      }
    }

    assert dispatch_gate(good) == :ok
  end

  describe "seed scripts" do
    for script <- @seed_scripts do
      test "TC-0930-08: #{script} wires the mock base, helper and downgrade guard" do
        content = File.read!(Path.join(@scripts_dir, unquote(script)))

        assert content =~ "SERVICE_TASK_MOCK_BASE_URL"
        assert content =~ "lib/seed_service_task_base.sh"
        assert content =~ ~r/jq -r '?\.version'?/
        assert content =~ "version_is_older"
        assert content =~ "not downgrading"
      end
    end

    test "TC-0930-09: shared helper exists and defines version_is_older" do
      helper = File.read!(Path.join(@scripts_dir, "lib/seed_service_task_base.sh"))

      assert helper =~ "version_is_older"
      assert helper =~ "SERVICE_TASK_MOCK_BASE_URL"
    end
  end
end
