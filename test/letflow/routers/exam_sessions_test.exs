defmodule Letflow.Routers.ExamSessionsTest do
  @moduledoc """
  REQ-335 -- integration tests for `Letflow.Routers.ExamSessions`, written by
  ELIXIR-DEV at WF-02 Step 2a to exercise the real `Letflow.Plugs.ApiPipeline`
  stack end to end (DIRECTIVE T-1: no mocked database, no bypassing
  `Letflow.Plugs.Authorize`). Not full acceptance-criteria coverage --
  TEST-DESIGNER writes that later in this pipeline (Step 2d+). Mirrors
  `test/letflow/routers/entities_test.exs`'s own full-pipeline-dispatch
  convention and `test/letflow/exam/session_test.exs`'s own hand-rolled exam
  fixture helpers (`Letflow.ExamFixtures`).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User

  # ── Full-pipeline dispatch ─────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil, opts \\ []) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> maybe_pin_trace_id(Keyword.get(opts, :trace_id))
    |> dispatch()
  end

  # `Letflow.Api.Error`'s `trace_id` is per-REQUEST correlation data, not
  # per-RESOURCE information (same reasoning
  # test/letflow/routers/entities_test.exs's own INV-5 byte-identity tests
  # state) -- pinning it is what makes a `resp_body == resp_body` comparison
  # a genuine byte-for-byte comparison of the whole document.
  defp maybe_pin_trace_id(conn, nil), do: conn
  defp maybe_pin_trace_id(conn, trace_id), do: put_req_header(conn, "x-trace-id", trace_id)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req335-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-335 Exam Sessions Router Test User",
      email: "req335-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp tenant(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      ExamFixtures.provisioned_tenant_with_exam_definitions(slug_prefix)

    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)

    %{tenant_id: tenant_id, schema_name: schema_name, slug: slug}
  end

  defp user_ctx(tenant, roles) do
    user = insert_user!(tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp candidate_ctx(tenant), do: user_ctx(tenant, ["TASK_WORKER"])

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp create_exam!(schema, attrs) do
    defaults = %{
      "title" => %{"en" => "Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 3,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => false
    }

    ExamFixtures.create_record!(schema, "exam", Map.merge(defaults, attrs))
  end

  defp create_question!(schema, category_id, attrs \\ %{}) do
    defaults = %{
      "category_id" => category_id,
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "active",
      "version" => 1,
      "stem" => %{"en" => "What is 2 + 2?"},
      "explanation" => %{"en" => "It is 4 because addition."}
    }

    ExamFixtures.create_record!(schema, "question", Map.merge(defaults, attrs))
  end

  defp create_option!(schema, question_id, sort_order, is_correct, attrs \\ %{}) do
    defaults = %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "is_correct" => is_correct,
      "text" => %{"en" => "Option #{sort_order}"}
    }

    ExamFixtures.create_record!(schema, "answer_option", Map.merge(defaults, attrs))
  end

  defp create_rule!(schema, exam_id, category_id, count) do
    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => count,
      "sort_order" => 0
    })
  end

  # One exam, one single-choice question with a correct and a wrong option.
  defp build_minimal_exam!(schema, exam_attrs \\ %{}) do
    category_id = Ecto.UUID.generate()
    exam = create_exam!(schema, exam_attrs)
    question = create_question!(schema, category_id)
    correct = create_option!(schema, question.record_id, 0, true)
    wrong = create_option!(schema, question.record_id, 1, false)
    create_rule!(schema, exam.record_id, category_id, 1)

    %{
      exam: exam,
      question_id: question.record_id,
      correct_id: correct.record_id,
      wrong_id: wrong.record_id
    }
  end

  defp field_values_for(schema, record_id) do
    {:ok, %Letflow.Entities.Record.Latest{field_values: field_values}} =
      Letflow.Entities.Record.Latest.get(record_id, "session", schema)

    field_values
  end

  defp start_session!(ctx, exam_id) do
    conn = request("POST", "/api/v1/exam-sessions", ctx, %{"exam_id" => exam_id})
    assert conn.status == 201
    json(conn)
  end

  # ── Route table sanity ───────────────────────────────────────────────────

  describe "route table" do
    test "every declared route resolves through a real, non-:Unknown policy key" do
      for {method, local_path, declared_key} <- Letflow.Routers.ExamSessions.__authz_routes__() do
        full_path = "/exam-sessions" <> if(local_path == "/", do: "", else: local_path)
        real_key = Letflow.Api.Authorization.endpoint_policy_key(method, full_path)

        assert real_key == declared_key,
               "#{method} #{full_path} declares #{inspect(declared_key)} but resolves to #{inspect(real_key)}"

        refute real_key == :Unknown
      end
    end

    test "five routes are declared, matching the moduledoc's route table" do
      routes = Letflow.Routers.ExamSessions.__authz_routes__()
      assert length(routes) == 5

      assert {"POST", "/", :ExamSessionStart} in routes
      assert {"GET", "/:id", :ExamSessionRead} in routes
      assert {"PUT", "/:id/answers/:question_id", :ExamSessionSave} in routes
      assert {"POST", "/:id/submit", :ExamSessionSubmit} in routes
      assert {"POST", "/:id/events", :ExamSessionReportEvent} in routes
    end
  end

  # ── Happy path: start -> autosave -> get state -> report event -> submit ──

  describe "the full candidate flow" do
    test "start, autosave, read state, report a signal, then submit" do
      tenant = tenant("req335-flow")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name)

      # start
      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]
      assert started["session"]["status"] == "in_progress"
      assert started["session"]["exam_id"] == exam.record_id
      assert is_integer(started["remaining_seconds"])
      assert [%{"question_id" => ^question_id}] = started["questions"]

      # autosave
      autosave_conn =
        request(
          "PUT",
          "/api/v1/exam-sessions/#{session_id}/answers/#{question_id}",
          ctx,
          %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
        )

      assert autosave_conn.status == 200
      assert %{"remaining_seconds" => remaining} = json(autosave_conn)
      assert is_integer(remaining)

      # read state
      state_conn = request("GET", "/api/v1/exam-sessions/#{session_id}", ctx)
      assert state_conn.status == 200
      state = json(state_conn)
      assert state["session"]["id"] == session_id
      assert [answer] = Map.values(state["answers"])
      assert answer["selected_option_ids"] == [correct_id]

      # report a benign signal
      event_conn =
        request("POST", "/api/v1/exam-sessions/#{session_id}/events", ctx, %{
          "type" => "tab_switch"
        })

      assert event_conn.status == 200
      assert %{"action_taken" => "log", "event_count" => 1} = json(event_conn)

      # submit
      submit_conn = request("POST", "/api/v1/exam-sessions/#{session_id}/submit", ctx)
      assert submit_conn.status == 200
      assert %{"status" => "submitted", "passed" => true} = json(submit_conn)
    end

    test "an invalid anti-cheat signal type is rejected with 400, never reaching AntiCheat's own domain check silently" do
      tenant = tenant("req335-badsignal")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      conn =
        request("POST", "/api/v1/exam-sessions/#{session_id}/events", ctx, %{
          "type" => "not_a_real_type"
        })

      assert conn.status == 400
    end
  end

  # ── ISS-0650: short-text autosave through the real HTTP PUT route ────────

  describe "short-text autosave (ISS-0650)" do
    test "PUT .../answers/:question_id with text_answer persists it, readable back via GET .../:id" do
      tenant = tenant("req335-shorttext")
      ctx = candidate_ctx(tenant)

      category_id = Ecto.UUID.generate()
      exam = create_exam!(tenant.schema_name, %{})
      question = create_question!(tenant.schema_name, category_id, %{"type" => "shorttext"})
      create_rule!(tenant.schema_name, exam.record_id, category_id, 1)

      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      autosave_conn =
        request(
          "PUT",
          "/api/v1/exam-sessions/#{session_id}/answers/#{question.record_id}",
          ctx,
          %{
            "text_answer" => "The mitochondria is the powerhouse of the cell.",
            "time_spent_seconds" => 8
          }
        )

      assert autosave_conn.status == 200

      state_conn = request("GET", "/api/v1/exam-sessions/#{session_id}", ctx)
      assert state_conn.status == 200
      state = json(state_conn)

      assert [answer] = Map.values(state["answers"])
      assert answer["text_answer"] == "The mitochondria is the powerhouse of the cell."
      assert answer["selected_option_ids"] == []
    end

    test "PUT .../answers/:question_id rejects text_answer for a single-choice question with 400" do
      tenant = tenant("req335-shorttext-reject")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      conn =
        request(
          "PUT",
          "/api/v1/exam-sessions/#{session_id}/answers/#{question_id}",
          ctx,
          %{"text_answer" => "should not be accepted", "time_spent_seconds" => 1}
        )

      assert conn.status == 400
    end
  end

  # ── Redaction: is_correct/likert_weight/likert_polarity/explanation never appear ──

  describe "GetSessionState redaction" do
    test "the response never carries is_correct or any other answer-key field" do
      tenant = tenant("req335-redact")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      conn = request("GET", "/api/v1/exam-sessions/#{session_id}", ctx)
      assert conn.status == 200

      # Byte-level check on the raw response body -- not just "it didn't
      # crash": none of the answer-key field NAMES appear anywhere in the
      # serialised JSON.
      refute conn.resp_body =~ "is_correct"
      refute conn.resp_body =~ "likert_weight"
      refute conn.resp_body =~ "likert_polarity"
      refute conn.resp_body =~ "explanation"

      state = json(conn)
      [question] = state["questions"]

      assert Map.keys(question) |> Enum.sort() == [
               "options",
               "question_id",
               "sort_order",
               "stem",
               "type"
             ]

      for option <- question["options"] do
        assert Map.keys(option) |> Enum.sort() == ["id", "text"]
      end
    end

    test "remaining_seconds is clamped at zero for an already-expired session" do
      tenant = tenant("req335-expired")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name, %{"time_limit_minutes" => 30})
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      # Force the session's own expires_at into the past, directly, via the
      # same Letflow.Entities.Records write path production code uses.
      {:ok, %{record: %Letflow.Entities.Record.Latest{field_values: field_values}}} =
        Letflow.Entities.Records.update_record(
          %{
            entity_type: "session",
            record_id: session_id,
            field_values:
              Map.put(
                field_values_for(tenant.schema_name, session_id),
                "expires_at",
                iso(DateTime.add(DateTime.utc_now(), -3600, :second))
              ),
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate()
          },
          tenant.schema_name
        )

      assert field_values["expires_at"]

      conn = request("GET", "/api/v1/exam-sessions/#{session_id}", ctx)
      assert conn.status == 200
      assert json(conn)["remaining_seconds"] == 0
    end
  end

  # ── Ownership: same 404 for "not yours" and "does not exist" (INV-5) ──────

  describe "cross-candidate ownership" do
    test "a candidate cannot reach another candidate's session -- identical 404 to a nonexistent id, on every session-scoped route" do
      tenant = tenant("req335-ownership")
      owner_ctx = candidate_ctx(tenant)
      other_ctx = candidate_ctx(tenant)
      %{exam: exam, question_id: question_id} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(owner_ctx, exam.record_id)

      nonexistent_id = Ecto.UUID.generate()
      trace_id = Ecto.UUID.generate()

      # GET
      not_owner_get =
        request("GET", "/api/v1/exam-sessions/#{session_id}", other_ctx, nil, trace_id: trace_id)

      not_found_get =
        request("GET", "/api/v1/exam-sessions/#{nonexistent_id}", other_ctx, nil,
          trace_id: trace_id
        )

      assert not_owner_get.status == 404
      assert not_owner_get.status == not_found_get.status
      assert not_owner_get.resp_body == not_found_get.resp_body

      # PUT answers
      not_owner_put =
        request(
          "PUT",
          "/api/v1/exam-sessions/#{session_id}/answers/#{question_id}",
          other_ctx,
          %{"selected_option_ids" => [], "time_spent_seconds" => 1},
          trace_id: trace_id
        )

      not_found_put =
        request(
          "PUT",
          "/api/v1/exam-sessions/#{nonexistent_id}/answers/#{question_id}",
          other_ctx,
          %{"selected_option_ids" => [], "time_spent_seconds" => 1},
          trace_id: trace_id
        )

      assert not_owner_put.status == 404
      assert not_owner_put.resp_body == not_found_put.resp_body

      # POST submit
      not_owner_submit =
        request("POST", "/api/v1/exam-sessions/#{session_id}/submit", other_ctx, nil,
          trace_id: trace_id
        )

      not_found_submit =
        request("POST", "/api/v1/exam-sessions/#{nonexistent_id}/submit", other_ctx, nil,
          trace_id: trace_id
        )

      assert not_owner_submit.status == 404
      assert not_owner_submit.resp_body == not_found_submit.resp_body

      # POST events
      not_owner_event =
        request(
          "POST",
          "/api/v1/exam-sessions/#{session_id}/events",
          other_ctx,
          %{"type" => "blur"},
          trace_id: trace_id
        )

      not_found_event =
        request(
          "POST",
          "/api/v1/exam-sessions/#{nonexistent_id}/events",
          other_ctx,
          %{"type" => "blur"},
          trace_id: trace_id
        )

      assert not_owner_event.status == 404
      assert not_owner_event.resp_body == not_found_event.resp_body
    end
  end

  # ── Tenant isolation (INV-1) ───────────────────────────────────────────

  describe "cross-tenant isolation" do
    test "a session in one tenant is invisible to a request scoped to another tenant" do
      tenant_a = tenant("req335-tenant-a")
      tenant_b = tenant("req335-tenant-b")
      ctx_a = candidate_ctx(tenant_a)
      ctx_b = candidate_ctx(tenant_b)

      %{exam: exam} = build_minimal_exam!(tenant_a.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx_a, exam.record_id)

      cross_tenant_conn = request("GET", "/api/v1/exam-sessions/#{session_id}", ctx_b)
      same_tenant_conn = request("GET", "/api/v1/exam-sessions/#{session_id}", ctx_a)

      assert cross_tenant_conn.status == 404
      assert same_tenant_conn.status == 200
    end
  end

  # ── Permission matrix ────────────────────────────────────────────────────

  describe "role gating" do
    test "PROCESS_DESIGNER (no TASK_WORKER, no PLATFORM_ADMIN) is forbidden from starting a session" do
      tenant = tenant("req335-role-designer")
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      ctx = user_ctx(tenant, ["PROCESS_DESIGNER"])

      conn = request("POST", "/api/v1/exam-sessions", ctx, %{"exam_id" => exam.record_id})
      assert conn.status == 403
    end

    test "TASK_WORKER (the candidate role) can start a session" do
      tenant = tenant("req335-role-taskworker")
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      ctx = candidate_ctx(tenant)

      conn = request("POST", "/api/v1/exam-sessions", ctx, %{"exam_id" => exam.record_id})
      assert conn.status == 201
    end
  end
end
