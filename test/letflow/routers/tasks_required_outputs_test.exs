defmodule Letflow.Routers.TasksRequiredOutputsTest do
  @moduledoc """
  REQ-460 -- router-level cases for rule C of the REQ-459 design (tests C-13, C-14, C-16
  and the HTTP half of C-1/C-2/C-4/C-4a): `POST /tasks/:id/complete` answers a refused
  completion with a retryable 422 `application/problem+json` (`code` `output_refused`,
  key NAMES only), for every role (TENANT_ADMIN is not exempt) and for an API-token
  request through the FULL `Letflow.Router` pipeline.

  Real Postgres and a real engine instance per test, inline definitions in a fresh
  tenant (no shipped fixture adopts `required_outputs`). The engine-level row assertions
  live in `test/letflow/engine_required_outputs_test.exs`; here the response and the
  audit record are the subject, plus the "nothing changed" row check once per path.

  See `test/specs/REQ-460.md`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.Engine.VariableSchema
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Tasks.init([])

  # ── fixtures ────────────────────────────────────────────────────────────

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: unique("req460-user"),
      display_name: "Req460 Caller Display",
      email: "req460-caller-#{System.unique_integer([:positive])}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp form do
    %{
      "type" => "object",
      "properties" => %{"decision" => %{"type" => "string"}, "note" => %{"type" => "string"}}
    }
  end

  # START -> task(HUMAN_TASK, USER assignee, required_outputs [decision]) -> END
  defp graph(assignee_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => assignee_id,
            "assignee_type" => "USER",
            "required_outputs" => ["decision"],
            "form_schema" => form()
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # Tenant + a caller user (the task's USER assignee) + an active definition with
  # variable_schemas (decision enum, a probe key not in the form) + a started instance.
  defp setup_case! do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req460-rt",
        display_name: "REQ-460 Router Test"
      )

    %Tenant{slug: slug} = Repo.get!(Tenant, tenant_id)
    caller = insert_user!(schema_name)

    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique("req460-rt-def"),
                 version: "1.0.0",
                 graph: graph(caller.id),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: definition}} =
             Definitions.activate(definition.id, prefix: schema_name)

    for {key, json_schema} <- [
          {"decision", %{"type" => "string", "enum" => ["approved", "rejected"]}},
          {"zz_probe_key", %{"type" => "number"}}
        ] do
      %VariableSchema{}
      |> VariableSchema.changeset(%{
        definition_id: definition.id,
        variable_key: key,
        json_schema: json_schema
      })
      |> Repo.insert!(prefix: schema_name)
    end

    assert {:ok, created} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{"seed" => "value"},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("start")
               },
               prefix: schema_name
             )

    task =
      EngineTask
      |> where([t], t.instance_id == ^created.instance_id)
      |> Repo.one!(prefix: schema_name)

    %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      slug: slug,
      caller: caller,
      instance_id: created.instance_id,
      task: task
    }
  end

  # Direct dispatch into Letflow.Routers.Tasks with a hand-assigned auth_context.
  defp complete_direct(ctx, roles, body) do
    conn(:post, "/#{ctx.task.id}/complete")
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{user_id: ctx.caller.id, tenant_id: ctx.tenant_id, roles: roles})
    |> assign(:trace_id, "req460-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, @opts))
  end

  # Full-pipeline dispatch: a real API token + tenant slug through Letflow.Router.
  defp complete_via_token(ctx, roles, body) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(ctx.caller.id, %{roles: roles, expires_at: nil},
        prefix: ctx.schema_name
      )

    conn(:post, "/api/v1/tasks/#{ctx.task.id}/complete", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp snapshot(ctx) do
    %{
      projection: Repo.get!(InstanceProjection, ctx.instance_id, prefix: ctx.schema_name),
      tokens:
        TokenRecord
        |> where([t], t.instance_id == ^ctx.instance_id)
        |> order_by([t], t.id)
        |> Repo.all(prefix: ctx.schema_name),
      task: Repo.get!(EngineTask, ctx.task.id, prefix: ctx.schema_name),
      events:
        Repo.aggregate(from(e in Event, where: e.instance_id == ^ctx.instance_id), :count,
          prefix: ctx.schema_name
        )
    }
  end

  defp refusal_rows(ctx) do
    Audit.Entry
    |> where([a], a.action == "task.completion_refused")
    |> Repo.all(prefix: ctx.schema_name)
  end

  defp assert_problem_422!(conn) do
    assert conn.status == 422
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"
    body = Jason.decode!(conn.resp_body)
    assert body["code"] == "output_refused"
    assert body["status"] == 422
    body
  end

  # No value, enum, stack, module or SQL text in a refusal body.
  defp assert_names_only!(conn, forbidden) do
    for text <- forbidden, do: refute(conn.resp_body =~ text, "body leaked #{inspect(text)}")

    for text <- [
          "Elixir.",
          "Ecto",
          "Postgrex",
          "SELECT ",
          "INSERT ",
          "** (",
          "lib/letflow",
          "enum"
        ] do
      refute conn.resp_body =~ text, "body leaked #{inspect(text)}"
    end
  end

  # ── C-1 / C-2 / C-3 via the router ──────────────────────────────────────

  describe "POST /tasks/:id/complete -- required key missing" do
    test "absent key: 422 problem naming only the key; nothing changed; one PII-free audit row" do
      ctx = setup_case!()
      before = snapshot(ctx)

      conn = complete_direct(ctx, ["TENANT_ADMIN"], %{"note" => "SUBMITTED-VALUE-460"})

      body = assert_problem_422!(conn)
      assert body["missing_keys"] == ["decision"]
      assert body["rejected_keys"] == []
      assert body["trace_id"] == "req460-trace"
      assert_names_only!(conn, ["SUBMITTED-VALUE-460", ctx.caller.email, ctx.caller.display_name])

      assert snapshot(ctx) == before
      assert before.task.status == :pending

      assert [entry] = refusal_rows(ctx)
      dump = inspect(entry, limit: :infinity)
      refute dump =~ "SUBMITTED-VALUE-460"
      refute dump =~ ctx.caller.email
      refute dump =~ ctx.caller.display_name
      refute dump =~ ctx.caller.username
      assert entry.actor_id == ctx.caller.id
    end

    test "null key: the same 422" do
      ctx = setup_case!()

      conn = complete_direct(ctx, ["TENANT_ADMIN"], %{"decision" => nil})

      body = assert_problem_422!(conn)
      assert body["missing_keys"] == ["decision"]
      assert body["rejected_keys"] == []
    end

    test "rework loop: a held decision does not count; the resubmission without it is refused" do
      ctx = setup_case!()

      # Complete once with a valid decision? That would finish the task. Instead hold the
      # value on the instance row directly, as a prior pass of a rework loop would have.
      InstanceProjection
      |> Repo.get!(ctx.instance_id, prefix: ctx.schema_name)
      |> Ecto.Changeset.change(%{variables: %{"seed" => "value", "decision" => "approved"}})
      |> Repo.update!(prefix: ctx.schema_name)

      conn = complete_direct(ctx, ["TENANT_ADMIN"], %{"note" => "n"})

      body = assert_problem_422!(conn)
      assert body["missing_keys"] == ["decision"]
    end
  end

  describe "POST /tasks/:id/complete -- a variable_schema rejects a value" do
    test "out-of-enum decision: 422 naming the key, never the value or the enum; not ERROR; the valid retry returns 200" do
      ctx = setup_case!()
      before = snapshot(ctx)

      conn = complete_direct(ctx, ["TENANT_ADMIN"], %{"decision" => "maybe-LEAKCHECK"})

      body = assert_problem_422!(conn)
      assert body["missing_keys"] == []
      assert body["rejected_keys"] == ["decision"]
      assert_names_only!(conn, ["maybe-LEAKCHECK", ~s("approved"), ~s("rejected")])

      assert snapshot(ctx) == before
      assert before.projection.status == :active
      assert [entry] = refusal_rows(ctx)
      refute inspect(entry, limit: :infinity) =~ "maybe-LEAKCHECK"

      retry = complete_direct(ctx, ["TENANT_ADMIN"], %{"decision" => "approved"})
      assert retry.status == 200
      assert Jason.decode!(retry.resp_body)["variables"]["decision"] == "approved"
    end

    test "C-4a: a rejected value on a key outside the form and required_outputs -> 422, both lists empty, the key name nowhere" do
      ctx = setup_case!()
      before = snapshot(ctx)

      conn =
        complete_direct(ctx, ["TENANT_ADMIN"], %{
          "decision" => "approved",
          "zz_probe_key" => "not-a-number"
        })

      body = assert_problem_422!(conn)
      assert body["missing_keys"] == []
      assert body["rejected_keys"] == []
      assert_names_only!(conn, ["zz_probe_key", "not-a-number"])

      assert snapshot(ctx) == before
      assert [entry] = refusal_rows(ctx)
      refute inspect(entry, limit: :infinity) =~ "zz_probe_key"
    end
  end

  # ── C-14 -- no role is exempt ───────────────────────────────────────────

  describe "C-14 -- the check holds for every role, TENANT_ADMIN included" do
    for role <- ["TENANT_ADMIN", "TASK_WORKER"] do
      test "a caller holding #{role} gets the same 422 and the task stays pending" do
        ctx = setup_case!()

        conn = complete_direct(ctx, [unquote(role)], %{})

        body = assert_problem_422!(conn)
        assert body["missing_keys"] == ["decision"]
        assert Repo.get!(EngineTask, ctx.task.id, prefix: ctx.schema_name).status == :pending
      end
    end
  end

  # ── C-13 -- API token through the full pipeline ─────────────────────────

  describe "C-13 -- the same refusals hold for an API-token request (full Letflow.Router pipeline)" do
    for role <- ["TENANT_ADMIN", "TASK_WORKER"] do
      test "token holding #{role}: missing key -> 422; enum rejection -> 422; valid retry -> 200" do
        ctx = setup_case!()
        before = snapshot(ctx)

        missing = complete_via_token(ctx, [unquote(role)], %{"note" => "n"})
        body = assert_problem_422!(missing)
        assert body["missing_keys"] == ["decision"]
        assert body["rejected_keys"] == []

        bad = complete_via_token(ctx, [unquote(role)], %{"decision" => "maybe-LEAKCHECK"})
        body = assert_problem_422!(bad)
        assert body["rejected_keys"] == ["decision"]
        assert_names_only!(bad, ["maybe-LEAKCHECK", ~s("approved"), ~s("rejected")])

        assert snapshot(ctx) == before
        assert length(refusal_rows(ctx)) == 2

        ok = complete_via_token(ctx, [unquote(role)], %{"decision" => "approved"})
        assert ok.status == 200
        assert Repo.get!(EngineTask, ctx.task.id, prefix: ctx.schema_name).status == :completed
      end
    end
  end
end
