defmodule Letflow.Modules.Exam do
  @moduledoc """
  The first real tenant-installable module extracted from the platform's exam
  domain, added in REQ-408. It owns the candidate-facing exam-session grant
  set and the route-policy mapping for the exam endpoints while leaving the
  actual exam runtime logic in `lib/letflow/exam/*` untouched until REQ-410.
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
end
