defmodule Letflow.Routers.ExamSessions do
  @moduledoc """
  REQ-335 -- the candidate-facing exam-session HTTP surface REQ-332
  (`Letflow.Exam.Session`) and REQ-333 (`Letflow.Exam.AntiCheat`) explicitly
  left unbuilt. A thin composition layer, no execution semantics of its
  own: every route below delegates its actual eligibility/ownership/
  deadline/debounce logic to those two already-authorized runtime modules
  (REQ-330's rule-2 bucket-C justifications for both are unchanged by this
  requirement -- see each module's own moduledoc). Mounted at
  `/exam-sessions` by `Letflow.Plugs.ApiPipeline`, the normal authenticated
  `/api/v1` forward every other tenant-scoped sub-router uses -- NOT decision
  `0028`'s unauthenticated capability-handle pattern (that is for
  certificate verification, REQ-323, still unimplemented; a candidate
  sitting an exam is an authenticated tenant user).

  Reference source: `backend/internal/sessions/handler.go`
  (`CreateSession`/`SaveAnswer`/`ReportEvent`/`SubmitSession`/
  `GetSessionState`). `SaveAnswer`'s real registration is
  `PUT /api/v1/portal/sessions/:id/answers/:questionId` -- re-verified
  against that reference's own handler comment and `SessionOptionResponse`'s
  shape (`ID`/`Text` only, confirming the redaction decision below), not
  assumed from the POST this requirement's own description inferred.

  ## Route table

  | Handler | Method/path | Delegate | Permission | Response |
  |---|---|---|---|---|
  | start_session | `POST /exam-sessions` | `Letflow.Exam.Session.create/3`, then `Letflow.Exam.Session.get_session_state_for_user/3` for the 201 body | `ExamSessionStart` | 201 / 400 / 403 / 409 / 422 |
  | get_session_state | `GET /exam-sessions/:id` | `Letflow.Exam.Session.get_session_state_for_user/3` | `ExamSessionRead` | 200 / 404 |
  | autosave_answer | `PUT /exam-sessions/:id/answers/:question_id` | `Letflow.Exam.Session.autosave_answer/4` | `ExamSessionSave` | 200 / 400 / 404 / 422 |
  | submit_session | `POST /exam-sessions/:id/submit` | `Letflow.Exam.Session.submit/3` | `ExamSessionSubmit` | 200 / 404 |
  | report_event | `POST /exam-sessions/:id/events` | `Letflow.Exam.AntiCheat.record_signal/4` | `ExamSessionReportEvent` | 200 / 400 / 404 / 422 |

  ## Deliberately NOT routed here, and why (REQ-335's own scope fence)

    * **Manual short-text grading queue** (`HandleListGradingQueue`/
      `HandleGetGradingDetail`/`HandleGradeAnswer`, FR-BB42) -- no admin
      grading-queue runtime exists; `Letflow.Exam.Scoring` (REQ-332) marks a
      short-text answer `pending_manual` and stops there. Building the
      runtime is not this requirement's job.
    * **Adaptive next-question selection** (`GetNextQuestion`, FR-BB72) --
      the stage file names adaptive selection as an unimplemented bucket-C
      behaviour with its own future requirement; no runtime exists to route
      to.
    * **Cross-session history / results-list views**
      (`GetExamHistory`/`HandleGetMyResults`, FR-BB41/FR-BB46) -- outside
      REQ-330's five analysed behaviours (start, autosave, submit,
      anti-cheat signal, and this route's own state read); `GetSessionResult`
      is also not routed here for the same reason -- a *result* view is a
      sixth behaviour this requirement's own dependency chain (REQ-330's
      five) never authorized, not a subset of the *state* read this module
      does implement.

  ## Permission vocabulary -- candidate-reachable, not `PLATFORM_ADMIN`-only

  `ExamSessionStart`/`ExamSessionRead`/`ExamSessionSave`/`ExamSessionSubmit`/
  `ExamSessionReportEvent` (minted in `Letflow.Api.Authorization`, following
  the `Entities*` naming precedent) are granted to `:CANDIDATE` -- a
  dedicated role added by ISS-0646 (see decision 0013's addendum) holding
  exactly these five permissions and nothing else, via
  `Letflow.Api.Authorization`'s `role_allows?(:CANDIDATE, ...)` clause. A
  candidate sitting an exam is exactly that: an ordinary authenticated
  tenant user reaching their OWN session. `TASK_WORKER` no longer holds
  these permissions. See `Letflow.Api.Authorization`'s own moduledoc
  "ExamSession*" section for the full reasoning, and its
  `endpoint_policy_key/2` clauses for the five real matrix entries backing
  these atoms (proven by `test/letflow/api/authorization_enforcement_test.exs`
  -- none is on that test's allowlist, none evaluates `:Unknown`).

  ## Ownership and tenant isolation (INV-1, INV-5, INV-8)

  No route below accepts a caller-supplied candidate identity. The
  candidate is always `conn.assigns.auth_context.user_id` (the authenticated
  caller's own id, resolved by `Letflow.Plugs.AuthPipeline` from their
  token) -- a path `:id` is a SESSION id, never a candidate id, and is never
  trusted as one. `prefix` always comes from `conn.assigns.scoped_opts`
  (`Letflow.Plugs.Authorize`'s own resolution), exactly as
  `Letflow.Routers.Entities` does; this router performs no `Repo` call of
  any kind. Every session-scoped delegate call passes straight through to
  `Letflow.Exam.Session`'s/`Letflow.Exam.AntiCheat`'s own
  `(:session_not_found | :not_owner)` ownership guard, and BOTH outcomes
  render through the exact same `Letflow.Api.Response.not_found/1` call --
  no detail, no distinguishing body -- so a candidate probing another
  candidate's `session_id` (same tenant or a different one; a session
  outside the caller's tenant is already invisible to the prefix-scoped
  `Letflow.Entities.Record.Latest.get/3` lookup those modules use) gets
  byte-identical 404s to a genuinely nonexistent id. A malformed
  (non-UUID) `:id`/`exam_id` is cast at the router boundary
  (`cast_uuid/1` below) and folded into that SAME path BEFORE any delegate
  call, for the same reason `Letflow.Routers.Entities`' own
  `cast_record_id/1` exists: `Letflow.Entities.Record.Latest`'s
  `record_id` column is `Ecto.UUID`-typed, and an uncast malformed string
  reaching a `Repo` query built against it raises `Ecto.Query.CastError`
  rather than returning a graceful not-found.

  ## The `is_correct`/answer-key redaction decision (REQ-335's own open question)

  `get_session_state`'s response NEVER carries `is_correct`,
  `likert_weight`, `likert_polarity` (from `answer_option`) or `explanation`
  (from `question`, which narrates the correct answer). The mitigation
  chosen is **hand-assembly, not a `Letflow.Entities.Query`-module
  field-redaction restriction** -- implemented one layer down, in
  `Letflow.Exam.Session.get_session_state_for_user/3` (that function's own
  `@doc` states the full reasoning: this response joins four entity types
  with no single `Letflow.Entities.Query.Compiler` result page for
  `FieldGrants` to redact, and this pack's `answer_option.json` itself
  records that no `entity_field_restrictions` row is configured for
  `is_correct` today, so a `FieldGrants`-based route would currently leak it
  outright). This router never touches `question`/`answer_option`
  `field_values` directly and never delegates to a generic entity-record
  serializer -- it only ever renders the already-redacted map
  `get_session_state_for_user/3` returns.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Exam.AntiCheat
  alias Letflow.Exam.Session

  # ── Start session ───────────────────────────────────────────────────────

  authz_post "/", :ExamSessionStart do
    handle_start_session(conn)
  end

  # ── Session-state read ──────────────────────────────────────────────────
  #
  # ⛔ Declared ABOVE the write routes below for readability only -- no
  # ordering hazard: GET and POST/PUT are independent Plug.Router dispatch
  # tables, and "/:id" (1 segment) cannot collide with "/:id/answers/:qid"
  # or "/:id/submit"/"/:id/events" (2-3 segments) regardless of order.

  authz_get "/:id", :ExamSessionRead do
    handle_get_session_state(conn, conn.params["id"])
  end

  # ── Autosave ─────────────────────────────────────────────────────────────
  #
  # PUT, matching backend/internal/sessions/handler.go's real registration
  # (`PUT .../sessions/:id/answers/:questionId`) -- re-verified against that
  # reference, not the POST this requirement's own description inferred.

  authz_put "/:id/answers/:question_id", :ExamSessionSave do
    handle_autosave_answer(conn, conn.params["id"], conn.params["question_id"])
  end

  # ── Submit ───────────────────────────────────────────────────────────────

  authz_post "/:id/submit", :ExamSessionSubmit do
    handle_submit_session(conn, conn.params["id"])
  end

  # ── Anti-cheat signal report ─────────────────────────────────────────────

  authz_post "/:id/events", :ExamSessionReportEvent do
    handle_report_event(conn, conn.params["id"])
  end

  match _ do
    Response.not_found(conn)
  end

  # ══ POST /exam-sessions ═══════════════════════════════════════════════
  #
  # `candidate_id` is ALWAYS conn.assigns.auth_context.user_id -- `exam_id`
  # is the only caller-supplied identifier here, and it names an exam, not a
  # candidate, so INV-1's "never trust a caller-supplied identity" concern
  # does not apply to it the way it applies to every :id below.

  @start_session_schema [
    %FieldConstraint{name: "exam_id", required: true, type: :string, reject_empty_string: true}
  ]

  defp handle_start_session(conn) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@start_session_schema, body),
         {:ok, exam_id} <- cast_uuid(Map.fetch!(attrs, "exam_id")) do
      render_start_session(
        conn,
        Session.create(candidate_id, exam_id, prefix),
        candidate_id,
        prefix
      )
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      # A malformed (non-UUID) exam_id can never resolve to a real exam --
      # the SAME outcome create/3 itself produces for a nonexistent exam_id
      # (lock_exam_row/2's nil branch -> :exam_not_active), reached without
      # ever handing Ecto a value that would raise Ecto.Query.CastError.
      :error ->
        render_start_session(conn, {:error, :exam_not_active}, candidate_id, prefix)
    end
  end

  # design (this module's own moduledoc): create/3's session_view() carries
  # no materialised question set, but a candidate starting a session needs
  # one to render the exam immediately -- so a successful create is followed
  # by ONE get_session_state_for_user/3 call, the same call the read route
  # itself uses, rather than inventing a second response-shaping path.
  defp render_start_session(conn, {:ok, %{id: session_id}}, candidate_id, prefix) do
    case Session.get_session_state_for_user(session_id, candidate_id, prefix) do
      {:ok, state} ->
        Response.created(conn, session_state_json(state))

      {:error, reason} ->
        Logger.warning(
          "exam session state read failed immediately after create: #{inspect(reason)}"
        )

        Response.internal_error(conn)
    end
  end

  # design §create/3's eligibility_error(), mirroring
  # backend/internal/sessions/handler.go's CreateSession status choices.
  defp render_start_session(conn, {:error, :not_assigned}, _candidate_id, _prefix),
    do: Response.forbidden(conn, "you are not assigned to this exam")

  defp render_start_session(conn, {:error, :exam_archived}, _candidate_id, _prefix),
    do: Response.forbidden(conn, "this exam has been archived and is no longer available")

  defp render_start_session(conn, {:error, :exam_not_active}, _candidate_id, _prefix),
    do: Response.unprocessable(conn, "this exam is not currently active")

  defp render_start_session(conn, {:error, :outside_availability_window}, _candidate_id, _prefix),
    do: Response.unprocessable(conn, "this exam is not available at this time")

  defp render_start_session(conn, {:error, :attempts_exhausted}, _candidate_id, _prefix),
    do: Response.unprocessable(conn, "you have used all allowed attempts for this exam")

  defp render_start_session(conn, {:error, :session_already_open}, _candidate_id, _prefix),
    do: Response.conflict(conn, "you already have an active session for this exam")

  defp render_start_session(conn, {:error, reason}, _candidate_id, _prefix) do
    Logger.warning("exam session create failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ GET /exam-sessions/:id ═════════════════════════════════════════════

  defp handle_get_session_state(conn, raw_session_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    case cast_uuid(raw_session_id) do
      {:ok, session_id} ->
        render_get_session_state(
          conn,
          Session.get_session_state_for_user(session_id, candidate_id, prefix)
        )

      :error ->
        Response.not_found(conn)
    end
  end

  # INV-5: :session_not_found and :not_owner render through the IDENTICAL
  # zero-detail Response.not_found/1 call -- a candidate probing another
  # candidate's session_id cannot distinguish "not yours" from "does not
  # exist" from the response bytes.
  defp render_get_session_state(conn, {:ok, state}),
    do: Response.ok(conn, session_state_json(state))

  defp render_get_session_state(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_get_session_state(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_get_session_state(conn, {:error, reason}) do
    Logger.warning("exam session state read failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ PUT /exam-sessions/:id/answers/:question_id ═══════════════════════
  #
  # `question_id` comes from the PATH, never the body -- one answer per
  # route call, matching backend/internal/sessions/handler.go's own
  # `PUT .../answers/:questionId` shape. `selected_option_ids` defaults to
  # `[]` when absent (a short-text question's autosave carries none), never
  # to `nil` -- Session.autosave_answer/4's own answer_attrs() map pattern
  # requires the key present. ISS-0650: `text_answer` (a short-text
  # question's free-text answer) is genuinely optional -- absent for every
  # OTHER question type's autosave, and `Session.check_answer_shape/3`
  # rejects a non-nil value sent for any of them.

  @autosave_schema [
    %FieldConstraint{name: "selected_option_ids", required: false, type: :array},
    %FieldConstraint{name: "time_spent_seconds", required: true, type: :integer},
    %FieldConstraint{name: "text_answer", required: false, type: :string}
  ]

  defp handle_autosave_answer(conn, raw_session_id, question_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    with {:ok, session_id} <- cast_session_id(raw_session_id),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@autosave_schema, body) do
      answer_attrs = %{
        question_id: question_id,
        selected_option_ids: Map.get(attrs, "selected_option_ids", []),
        time_spent_seconds: Map.fetch!(attrs, "time_spent_seconds"),
        text_answer: Map.get(attrs, "text_answer")
      }

      render_autosave(
        conn,
        Session.autosave_answer(session_id, candidate_id, answer_attrs, prefix)
      )
    else
      :not_found ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # design (autosave_error()), mirroring handler.go's SaveAnswer status
  # choices. :session_not_found and :not_owner render through the SAME
  # zero-detail 404 (INV-5).
  defp render_autosave(conn, {:ok, %{remaining_seconds: remaining_seconds}}) do
    Response.ok(conn, %{"remaining_seconds" => remaining_seconds})
  end

  defp render_autosave(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_autosave(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_autosave(conn, {:error, :session_not_in_progress}),
    do: Response.unprocessable(conn, "session is not in progress")

  defp render_autosave(conn, {:error, :deadline_passed}),
    do: Response.unprocessable(conn, "your exam session has expired")

  defp render_autosave(conn, {:error, :question_not_in_session}),
    do: Response.bad_request(conn, "question does not belong to this session")

  defp render_autosave(conn, {:error, :answer_shape_invalid}),
    do: Response.bad_request(conn, "answer shape is invalid for this question type")

  defp render_autosave(conn, {:error, :option_not_in_question}) do
    Response.bad_request(
      conn,
      "one or more supplied option ids do not belong to this question"
    )
  end

  defp render_autosave(conn, {:error, reason}) do
    Logger.warning("exam session autosave failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ POST /exam-sessions/:id/submit ═════════════════════════════════════

  defp handle_submit_session(conn, raw_session_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    case cast_uuid(raw_session_id) do
      {:ok, session_id} ->
        render_submit(conn, Session.submit(session_id, candidate_id, prefix))

      :error ->
        Response.not_found(conn)
    end
  end

  defp render_submit(conn, {:ok, outcome}),
    do: Response.ok(conn, submission_outcome_json(outcome))

  defp render_submit(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_submit(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_submit(conn, {:error, reason}) do
    Logger.warning("exam session submit failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ POST /exam-sessions/:id/events ═════════════════════════════════════
  #
  # `action_taken` is NEVER accepted from the caller -- there is no such
  # field in @report_event_schema, matching AntiCheat.record_signal/4's own
  # parameter list (no action_taken argument at all).

  @report_event_schema [
    %FieldConstraint{name: "type", required: true, type: :string, reject_empty_string: true}
  ]

  defp handle_report_event(conn, raw_session_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    with {:ok, session_id} <- cast_session_id(raw_session_id),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@report_event_schema, body) do
      signal_type = signal_type_atom(Map.fetch!(attrs, "type"))

      render_report_event(
        conn,
        AntiCheat.record_signal(session_id, candidate_id, signal_type, prefix)
      )
    else
      :not_found ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # Closed-set conversion -- NEVER String.to_existing_atom/1 on caller input.
  # An unrecognized string maps to a fixed literal atom that is a member of
  # no valid @valid_signal_types list AntiCheat.record_signal/4 checks
  # against, so it is rejected there as :invalid_signal_type -- exactly the
  # same outcome check_signal_type/1 gives a truly invalid value, without
  # ever calling String.to_existing_atom/1 on untrusted input.
  defp signal_type_atom("tab_switch"), do: :tab_switch
  defp signal_type_atom("blur"), do: :blur
  defp signal_type_atom("fullscreen_exit"), do: :fullscreen_exit
  defp signal_type_atom(_other), do: :__invalid_signal_type__

  # design (signal_error()), mirroring handler.go's ReportEvent status
  # choices. :session_not_found and :not_owner render through the SAME
  # zero-detail 404 (INV-5).
  defp render_report_event(conn, {:ok, outcome}),
    do: Response.ok(conn, signal_outcome_json(outcome))

  defp render_report_event(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_report_event(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_report_event(conn, {:error, :invalid_signal_type}) do
    Response.bad_request(conn, "type must be one of: tab_switch, blur, fullscreen_exit")
  end

  defp render_report_event(conn, {:error, :session_not_in_progress}),
    do: Response.unprocessable(conn, "session is not in progress")

  defp render_report_event(conn, {:error, :deadline_passed}),
    do: Response.unprocessable(conn, "your exam session has expired")

  defp render_report_event(conn, {:error, reason}) do
    Logger.warning("exam session anti-cheat signal report failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ JSON shaping (hand-selected fields only -- see this module's own
  # moduledoc redaction section) ══════════════════════════════════════════

  defp session_view_json(%{
         id: id,
         exam_id: exam_id,
         candidate_id: candidate_id,
         status: status,
         seed: seed,
         started_at: started_at,
         expires_at: expires_at,
         score_pct: score_pct,
         passed: passed
       }) do
    %{
      "id" => id,
      "exam_id" => exam_id,
      "candidate_id" => candidate_id,
      "status" => Atom.to_string(status),
      "seed" => seed,
      "started_at" => DateTime.to_iso8601(started_at),
      "expires_at" => DateTime.to_iso8601(expires_at),
      "score_pct" => score_pct,
      "passed" => passed
    }
  end

  defp session_state_json(%{
         session: session,
         remaining_seconds: remaining_seconds,
         questions: questions,
         answers: answers
       }) do
    %{
      "session" => session_view_json(session),
      "remaining_seconds" => remaining_seconds,
      "questions" => Enum.map(questions, &question_state_json/1),
      "answers" =>
        Map.new(answers, fn {question_id, answer} -> {question_id, answer_json(answer)} end)
    }
  end

  # ⛔ Only id/sort_order/type/stem/options -- NEVER a question's
  # `explanation`/`difficulty`/`category_id`/`status`/`version` field.
  defp question_state_json(%{
         question_id: question_id,
         sort_order: sort_order,
         type: type,
         stem: stem,
         options: options
       }) do
    %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "type" => Atom.to_string(type),
      "stem" => stem,
      "options" =>
        Enum.map(options, fn %{id: id, text: text} -> %{"id" => id, "text" => text} end)
    }
  end

  defp answer_json(%{
         selected_option_ids: selected_option_ids,
         text_answer: text_answer,
         time_spent_seconds: time_spent_seconds,
         saved_at: saved_at
       }) do
    %{
      "selected_option_ids" => selected_option_ids,
      "text_answer" => text_answer,
      "time_spent_seconds" => time_spent_seconds,
      "saved_at" => saved_at
    }
  end

  defp submission_outcome_json(%{
         status: status,
         total_score: total_score,
         total_max_score: total_max_score,
         percentage: percentage,
         passed: passed
       }) do
    %{
      "status" => Atom.to_string(status),
      "total_score" => total_score,
      "total_max_score" => total_max_score,
      "percentage" => percentage,
      "passed" => passed
    }
  end

  defp signal_outcome_json(%{
         action_taken: action_taken,
         event_count: event_count,
         warning: warning,
         submission: submission
       }) do
    %{
      "action_taken" => Atom.to_string(action_taken),
      "event_count" => event_count,
      "warning" => warning,
      "submission" => if(submission, do: submission_outcome_json(submission), else: nil)
    }
  end

  # ══ Shared plumbing ═══════════════════════════════════════════════════

  @spec prefix!(Plug.Conn.t()) :: String.t()
  defp prefix!(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  defp validate_schema(schema, body) do
    case Validation.validate(schema, body) do
      {:ok, attrs} -> {:ok, attrs}
      {:errors, field_errors} -> {:errors, field_errors}
    end
  end

  # A malformed session id can never own anything -- fold it into the SAME
  # not-found path :session_not_found/:not_owner already take (INV-5),
  # before ever handing Ecto a value that would raise Ecto.Query.CastError
  # against Letflow.Entities.Record.Latest's UUID-typed record_id column.
  defp cast_session_id(raw_session_id) do
    case cast_uuid(raw_session_id) do
      {:ok, session_id} -> {:ok, session_id}
      :error -> :not_found
    end
  end

  @spec cast_uuid(String.t()) :: {:ok, String.t()} | :error
  defp cast_uuid(raw), do: Ecto.UUID.cast(raw)
end
