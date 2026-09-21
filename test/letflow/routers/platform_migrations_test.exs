defmodule Letflow.Routers.PlatformMigrationsTest do
  @moduledoc """
  HTTP/permission-level tests for `Letflow.Routers.PlatformMigrations`
  (REQ-374). See `test/specs/REQ-374.md` for the full AC-to-test mapping, and
  `lib/letflow/design/req374-tenant-migration-fanout-runner.md` §7/§7.1 for
  the design rationale each test below implements directly.

  Dispatch is direct `Letflow.Routers.PlatformMigrations.call/2` with
  `conn.assigns[:auth_context]` set directly (bypassing the full
  `Letflow.Router` -> `Letflow.Plugs.ApiPipeline` -> `AuthPipeline` chain) --
  the same pattern `test/letflow/routers/tenants_test.exs` already
  establishes for a router mounted with no tenant-scoped `:prefix`
  preamble, whose own `with_authorization/4`-successor
  (`Letflow.Plugs.Authorize`) reads `conn.assigns.auth_context` directly, so
  nothing about the handlers under test depends on how that assign got
  populated. The caller's OWN `tenant_id` is irrelevant to this router's
  authorization (design doc §7's pure-role gate, mirroring REQ-075/REQ-076's
  own precedent) -- only `roles` matters, so negative (403) tests use a bare
  `Ecto.UUID.generate()` and never provision a tenant for the caller. A
  positive (200) test still needs one real, active, provisioned company as
  the rollout's TARGET (a company the change is actually applied to),
  provisioned via `Letflow.TenantFixture.provisioned_tenant!/1` with an
  active `"invoice"` definition, same as `migration_rollout_test.exs`.

  Uses `Letflow.DataCase` (real Postgres) and `async: false`, matching every
  other router test in this suite that provisions a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Platform.MigrationRollout.Outcome
  alias Letflow.Platform.MigrationRollout.Rollout
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @opts Letflow.Routers.PlatformMigrations.init([])

  defp build_conn(method, path, fields) do
    roles = Keyword.get(fields, :roles, [])
    body = Keyword.get(fields, :body, nil)

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
      tenant_id: Ecto.UUID.generate(),
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.PlatformMigrations.call(conn, @opts)

  defp unique_attribute(base), do: "#{base}_#{System.unique_integer([:positive])}"

  defp create_active_definition!(schema, entity_name) do
    definition = %{
      name: entity_name,
      display_name: String.capitalize(entity_name),
      fields: [%{name: "amount", type: :string, queried: true}]
    }

    assert {:ok, entity_definition} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, _activated} =
             Definitions.activate_definition(
               entity_definition.name,
               Ecto.UUID.generate(),
               "go-live",
               schema
             )
  end

  defp cleanup_rollout_on_exit!(entity_type, attribute) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      case Repo.get_by(Rollout, entity_type: entity_type, attribute: attribute) do
        %Rollout{id: rollout_id} ->
          Repo.delete_all(from(o in Outcome, where: o.rollout_id == ^rollout_id))
          Repo.delete_all(from(r in Rollout, where: r.id == ^rollout_id))

        nil ->
          :ok
      end

      Repo.delete_all(
        from(cp in Letflow.TenantProvisioning.ColumnPromotion,
          where: cp.entity_type == ^entity_type and cp.attribute == ^attribute
        )
      )
    end)
  end

  defp start_body(entity_type, attribute) do
    %{
      "entity_type" => entity_type,
      "attribute" => attribute,
      "column_spec" => %{"pg_type" => "text"}
    }
  end

  # ---------------------------------------------------------------------
  # Permission gate -- 403 for a non-PLATFORM_ADMIN caller on all three
  # routes, no Repo call of any kind reaching MigrationRollout.
  # ---------------------------------------------------------------------

  describe "permission gate -- non-PLATFORM_ADMIN caller" do
    test "POST /rollouts returns 403 and creates no rollout row" do
      entity_type = "perm_gate_#{System.unique_integer([:positive])}"
      attribute = "sku"

      resp =
        build_conn(:post, "/rollouts", roles: ["PROCESS_DESIGNER"], body: start_body(entity_type, attribute))
        |> dispatch()

      assert resp.status == 403

      assert Jason.decode!(resp.resp_body) == %{
               "type" => "https://bpm.example.com/problems/forbidden",
               "title" => "Forbidden",
               "status" => 403,
               "detail" => "insufficient permissions",
               "trace_id" => "fixed-test-trace-id"
             }

      assert Repo.get_by(Rollout, entity_type: entity_type, attribute: attribute) == nil
    end

    test "GET /rollouts/:id returns 403 for a non-existent id too (rejected before the domain lookup)" do
      resp =
        build_conn(:get, "/rollouts/#{Ecto.UUID.generate()}", roles: ["PROCESS_DESIGNER"])
        |> dispatch()

      assert resp.status == 403
    end

    test "POST /rollouts/:id/resume returns 403 for a non-existent id too (rejected before the domain lookup)" do
      resp =
        build_conn(:post, "/rollouts/#{Ecto.UUID.generate()}/resume", roles: ["PROCESS_DESIGNER"])
        |> dispatch()

      assert resp.status == 403
    end

    test "a caller with no roles at all is rejected the same way" do
      entity_type = "perm_gate_noroles_#{System.unique_integer([:positive])}"
      attribute = "sku"

      resp =
        build_conn(:post, "/rollouts", roles: [], body: start_body(entity_type, attribute))
        |> dispatch()

      assert resp.status == 403
    end
  end

  # ---------------------------------------------------------------------
  # Permission gate -- PLATFORM_ADMIN succeeds on all three routes.
  # ---------------------------------------------------------------------

  describe "permission gate -- PLATFORM_ADMIN caller" do
    test "POST /rollouts, GET /rollouts/:id, and POST /rollouts/:id/resume all succeed" do
      attribute = unique_attribute("amount")
      entity_type = "invoice"

      company = TenantFixture.provisioned_tenant!(slug_prefix: "req374-perm-admin")
      create_active_definition!(company.schema_name, entity_type)
      cleanup_rollout_on_exit!(entity_type, attribute)

      start_resp =
        build_conn(:post, "/rollouts",
          roles: ["PLATFORM_ADMIN"],
          body: start_body(entity_type, attribute)
        )
        |> dispatch()

      assert start_resp.status == 200
      start_body_decoded = Jason.decode!(start_resp.resp_body)
      rollout_id = start_body_decoded["rollout"]["id"]
      assert is_binary(rollout_id)

      outcome =
        Enum.find(start_body_decoded["outcomes"], &(&1["tenant_id"] == company.tenant_id))

      assert outcome["status"] == "succeeded"
      assert is_binary(outcome["completed_at"])

      status_resp =
        build_conn(:get, "/rollouts/#{rollout_id}", roles: ["PLATFORM_ADMIN"]) |> dispatch()

      assert status_resp.status == 200
      status_body = Jason.decode!(status_resp.resp_body)
      assert status_body["rollout"]["id"] == rollout_id

      resume_resp =
        build_conn(:post, "/rollouts/#{rollout_id}/resume", roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resume_resp.status == 200
      resume_body = Jason.decode!(resume_resp.resp_body)
      assert resume_body["rollout"]["id"] == rollout_id
    end

    test "GET /rollouts/:id returns 404 for an unknown id (not 403 -- the permission check already passed)" do
      resp =
        build_conn(:get, "/rollouts/#{Ecto.UUID.generate()}", roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp.status == 404
    end
  end

  # ---------------------------------------------------------------------
  # The permission decision is stated in the moduledoc, by name.
  # ---------------------------------------------------------------------

  describe "moduledoc states the permission decision by name" do
    test "Letflow.Routers.PlatformMigrations's moduledoc names :TenantsManage and its reasoning" do
      {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Routers.PlatformMigrations)

      assert moduledoc =~ ":TenantsManage"
      assert moduledoc =~ "PLATFORM_ADMIN"
    end
  end
end
