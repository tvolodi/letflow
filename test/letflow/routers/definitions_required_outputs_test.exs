defmodule Letflow.Routers.DefinitionsRequiredOutputsTest do
  @moduledoc """
  HTTP surface of REQ-461's checks through `Letflow.Routers.Definitions` (same dispatch as
  `definitions_write_test.exs`: direct `call/2`, `auth_context` assigned). See
  `test/specs/REQ-461.md`.

    * check 1 -> 422 `errors[].code` `invalid_required_outputs` /
      `required_outputs_on_non_human_task` at POST /, PUT /:id, PATCH /:id, POST /import
    * check 2 -> reported by POST /:id/validate (422) and refused by POST /:id/activate (422);
      NOT rejected at POST / (201)
    * check 3 -> the `decision_key_not_required:` WARNING in the POST /:id/validate 200 body
      `warnings` (`status` stays `valid`), absent when `required_outputs` declares the key, and
      not in the POST /:id/activate 200 body

  `async: false` (tenant provisioning). No helper has a default argument (ISS-0069).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Definitions.init([])
  @writer_role "PROCESS_DESIGNER"
  @condition "decision == \"approved\""
  @decision_entry %{
    "variable_key" => "decision",
    "json_schema" => %{"type" => "string", "enum" => ["approved", "rejected"]}
  }

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp build_conn(method, path, tenant, body) do
    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: [@writer_role]
    })
    |> assign(:trace_id, "req461-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Definitions.call(conn, @opts)

  defp decision_graph(task_attrs) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "t",
          "node_type" => "HUMAN_TASK",
          "attributes" =>
            Map.merge(
              %{
                "role" => "approver",
                "form_schema" => %{"properties" => %{"decision" => %{"type" => "string"}}}
              },
              task_attrs
            )
        },
        %{"id" => "end-a", "node_type" => "END"},
        %{"id" => "end-b", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e-start", "source" => "start", "target" => "t"},
        %{"id" => "e-cond", "source" => "t", "target" => "end-a", "condition" => @condition},
        %{"id" => "e-def", "source" => "t", "target" => "end-b", "is_default" => true}
      ]
    }
  end

  defp create_body(graph, variable_schemas) do
    body = %{"name" => unique("req461-http"), "version" => "1.0.0", "graph" => graph}
    if variable_schemas == [], do: body, else: Map.put(body, "variable_schemas", variable_schemas)
  end

  # POST / and returns the decoded 201 body.
  defp post_create!(tenant, graph, variable_schemas) do
    conn = build_conn("POST", "/", tenant, create_body(graph, variable_schemas)) |> dispatch()
    assert conn.status == 201, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp error_codes(conn), do: conn.resp_body |> Jason.decode!() |> Map.fetch!("errors")

  defp definition_count(tenant),
    do:
      Letflow.Repo.aggregate(Definitions.ProcessDefinition, :count, :id,
        prefix: tenant.schema_name
      )

  defp tenant!(slug), do: TenantFixture.provisioned_tenant!(slug_prefix: slug)

  # ---------------------------------------------------------------------------------------
  # Check 1
  # ---------------------------------------------------------------------------------------

  describe "check 1 over HTTP" do
    test "POST / with a non-list required_outputs is a 422 naming :invalid_required_outputs and the node; no row" do
      tenant = tenant!("req461-http-create")

      conn =
        build_conn(
          "POST",
          "/",
          tenant,
          create_body(decision_graph(%{"required_outputs" => "decision"}), [])
        )
        |> dispatch()

      assert conn.status == 422
      assert [error] = error_codes(conn)
      assert error["code"] == "invalid_required_outputs"
      assert error["message"] =~ "Node 't'"
      assert definition_count(tenant) == 0
    end

    test "POST / with a duplicate key and with an empty entry: one invalid_required_outputs each" do
      tenant = tenant!("req461-http-dup")

      for bad <- [["decision", "decision"], [""]] do
        conn =
          build_conn(
            "POST",
            "/",
            tenant,
            create_body(decision_graph(%{"required_outputs" => bad}), [])
          )
          |> dispatch()

        assert conn.status == 422
        assert [%{"code" => "invalid_required_outputs"}] = error_codes(conn)
      end
    end

    test "POST / with required_outputs on a gateway is a 422 :required_outputs_on_non_human_task naming the node" do
      tenant = tenant!("req461-http-gw")

      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "gw",
            "node_type" => "EXCLUSIVE_GATEWAY",
            "attributes" => %{"required_outputs" => ["decision"]}
          },
          %{"id" => "end-a", "node_type" => "END"},
          %{"id" => "end-b", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "gw"},
          %{"id" => "e2", "source" => "gw", "target" => "end-a", "condition" => @condition},
          %{"id" => "e3", "source" => "gw", "target" => "end-b", "is_default" => true}
        ]
      }

      conn = build_conn("POST", "/", tenant, create_body(graph, [@decision_entry])) |> dispatch()

      assert conn.status == 422
      assert [error] = error_codes(conn)
      assert error["code"] == "required_outputs_on_non_human_task"
      assert error["message"] =~ "Node 'gw'"
    end

    test "valid neighbour: POST / with a well-shaped required_outputs is a 201 DRAFT" do
      tenant = tenant!("req461-http-ok")

      body =
        post_create!(tenant, decision_graph(%{"required_outputs" => ["decision"]}), [
          @decision_entry
        ])

      assert body["status"] == "DRAFT"
    end

    test "PUT /:id and PATCH /:id reject a non-list required_outputs with 422 invalid_required_outputs and store nothing" do
      tenant = tenant!("req461-http-update")

      created =
        post_create!(tenant, decision_graph(%{"required_outputs" => ["decision"]}), [
          @decision_entry
        ])

      bad_graph = decision_graph(%{"required_outputs" => %{"decision" => true}})

      put_conn =
        build_conn("PUT", "/#{created["id"]}", tenant, %{
          "name" => unique("req461-put"),
          "version" => "2.0.0",
          "graph" => bad_graph
        })
        |> dispatch()

      assert put_conn.status == 422
      assert [%{"code" => "invalid_required_outputs"}] = error_codes(put_conn)

      patch_conn =
        build_conn("PATCH", "/#{created["id"]}", tenant, %{"graph" => bad_graph}) |> dispatch()

      assert patch_conn.status == 422
      assert [%{"code" => "invalid_required_outputs"}] = error_codes(patch_conn)

      assert {:ok, stored} = Definitions.get_by_id(created["id"], prefix: tenant.schema_name)

      assert stored.graph["nodes"]
             |> Enum.find(&(&1["id"] == "t"))
             |> get_in(["attributes", "required_outputs"]) == ["decision"]
    end

    test "POST /import with a non-list required_outputs is a 422" do
      tenant = tenant!("req461-http-import")

      body = %{
        "bpm_export_schema_version" => Definitions.ExportImport.export_schema_version(),
        "name" => unique("req461-import"),
        "version" => "1.0.0",
        "graph" => decision_graph(%{"required_outputs" => "decision"})
      }

      conn = build_conn("POST", "/import", tenant, body) |> dispatch()

      assert conn.status == 422
      assert Enum.any?(error_codes(conn), &(&1["code"] == "invalid_required_outputs"))
      assert definition_count(tenant) == 0
    end
  end

  # ---------------------------------------------------------------------------------------
  # Check 2
  # ---------------------------------------------------------------------------------------

  describe "check 2 over HTTP" do
    test "POST / with a key that has no variable_schema is NOT rejected (201)" do
      tenant = tenant!("req461-http-c2-create")
      body = post_create!(tenant, decision_graph(%{"required_outputs" => ["decision"]}), [])
      assert body["status"] == "DRAFT"
    end

    test "POST /:id/validate reports it (422, node id and key in the message) with NO variable_schemas at all" do
      tenant = tenant!("req461-http-c2-validate-empty")
      created = post_create!(tenant, decision_graph(%{"required_outputs" => ["decision"]}), [])

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 422
      assert [error] = error_codes(conn)
      assert error["code"] == "required_output_without_variable_schema"
      assert error["message"] =~ "Node 't'"
      assert error["message"] =~ "'decision'"
    end

    test "POST /:id/validate reports it when another variable_schema exists" do
      tenant = tenant!("req461-http-c2-validate-other")

      created =
        post_create!(tenant, decision_graph(%{"required_outputs" => ["decision"]}), [
          %{"variable_key" => "note", "json_schema" => %{"type" => "string"}}
        ])

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 422
      assert [%{"code" => "required_output_without_variable_schema"}] = error_codes(conn)
    end

    test "valid neighbour: POST /:id/validate is 200 'valid' when the key has a variable_schema" do
      tenant = tenant!("req461-http-c2-validate-ok")

      created =
        post_create!(tenant, decision_graph(%{"required_outputs" => ["decision"]}), [
          @decision_entry
        ])

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "valid"
      assert body["findings"] == []
    end

    test "POST /:id/activate refuses it (422 required_output_without_variable_schema) and the definition stays DRAFT" do
      tenant = tenant!("req461-http-c2-activate")
      created = post_create!(tenant, decision_graph(%{"required_outputs" => ["decision"]}), [])

      conn = build_conn("POST", "/#{created["id"]}/activate", tenant, nil) |> dispatch()

      assert conn.status == 422
      assert [error] = error_codes(conn)
      assert error["code"] == "required_output_without_variable_schema"
      assert error["message"] =~ "'decision'"

      assert {:ok, %{status: :draft}} =
               Definitions.get_by_id(created["id"], prefix: tenant.schema_name)
    end
  end

  # ---------------------------------------------------------------------------------------
  # Check 3
  # ---------------------------------------------------------------------------------------

  describe "check 3 over HTTP" do
    test "POST /:id/validate 200 carries the decision_key_not_required: warning; status stays 'valid', findings []" do
      tenant = tenant!("req461-http-c3-warn")
      created = post_create!(tenant, decision_graph(%{}), [@decision_entry])

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "valid"
      assert body["findings"] == []

      assert [line] =
               Enum.filter(
                 body["warnings"],
                 &String.starts_with?(&1, "decision_key_not_required:")
               )

      assert line =~ "decision"
      assert line =~ "'e-cond'"
    end

    test "valid neighbour: required_outputs: [decision] leaves no decision_key_not_required: warning in the body" do
      tenant = tenant!("req461-http-c3-clean")

      created =
        post_create!(tenant, decision_graph(%{"required_outputs" => ["decision"]}), [
          @decision_entry
        ])

      conn = build_conn("POST", "/#{created["id"]}/validate", tenant, nil) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      refute Enum.any?(body["warnings"], &String.starts_with?(&1, "decision_key_not_required:"))
    end

    test "POST /:id/activate of a definition that WOULD warn is 200 and its body carries no warnings and no decision_key_not_required" do
      tenant = tenant!("req461-http-c3-activate")
      created = post_create!(tenant, decision_graph(%{}), [@decision_entry])

      conn = build_conn("POST", "/#{created["id"]}/activate", tenant, nil) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ACTIVE"
      refute Map.has_key?(body, "warnings")
      refute conn.resp_body =~ "decision_key_not_required"
    end
  end
end
