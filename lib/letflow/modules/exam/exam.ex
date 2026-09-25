defmodule Letflow.Modules.Exam do
  @moduledoc """
  The first real tenant-installable module extracted from the platform's exam
  domain, added in REQ-408. It owns the candidate-facing exam-session grant
  set and the route-policy mapping for the exam endpoints.

  REQ-410 completes the extraction: the runtime logic and HTTP router are now
  co-located under `lib/letflow/modules/exam/`, served at
  `/api/v1/modules/exam/exam-sessions/…` via the D4/D5 gate in
  `Letflow.Routers.Modules` (REQ-404).
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "exam",
    version: "0.1.0",
    depends_on: [],
    pack: nil,
    permissions: [
      :ExamSessionStart,
      :ExamSessionRead,
      :ExamSessionSave,
      :ExamSessionSubmit,
      :ExamSessionReportEvent,
      :ExamCertificateIssue
    ],
    role_grants: %{
      CANDIDATE: [
        :ExamSessionStart,
        :ExamSessionRead,
        :ExamSessionSave,
        :ExamSessionSubmit,
        :ExamSessionReportEvent,
        :ExamCertificateIssue
      ]
    },
    required_roles: [],
    settings_schema: nil,
    route_policies: [
      {"POST", "/exam-sessions", :ExamSessionStart},
      {"GET", "/exam-sessions/available", :ExamSessionStart},
      {"GET", "/exam-sessions/:id", :ExamSessionRead},
      {"PUT", "/exam-sessions/:id/answers/:question_id", :ExamSessionSave},
      {"POST", "/exam-sessions/:id/submit", :ExamSessionSubmit},
      {"POST", "/exam-sessions/:id/events", :ExamSessionReportEvent},
      {"POST", "/exam-sessions/:id/certificate", :ExamCertificateIssue},
      {"GET", "/exam-sessions/:id/certificate/download", :ExamCertificateIssue}
    ]
  )

  @impl true
  def router, do: Letflow.Modules.Exam.Router
end
