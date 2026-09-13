defmodule Letflow.Packs.Bilimbaga do
  @moduledoc """
  ISS-0647 fix -- the one piece of bilimbaga-pack-specific content this
  codebase is missing: `entity_field_restrictions` rows for the pack's own
  answer-key fields.

  ## Why this isn't inside `Letflow.Definitions.SolutionPack`

  `SolutionPack.install/3` is deliberately a generic, definitions-only
  installer with no bilimbaga-specific business logic anywhere in it (see
  decisions 0026/0027/0029 -- the pack-section set is closed and nothing
  pack-specific is hardcoded into the generic installer). Seeding these
  four rows is bilimbaga-specific knowledge (which fields on which entity
  types are the answer key), so it does not belong there. This module is
  new, narrowly-scoped glue for exactly that one piece of knowledge --
  nothing else.

  ## The gap this closes (ISS-0647)

  `priv/packs/bilimbaga/entity_definitions/answer_option.json`'s own
  description documents this as a KNOWN, DELIBERATE gap: "This pack does
  not configure a field grant; it only ensures is_correct is a first-class
  promoted field on its own record, so that redaction is expressible at
  all." `Letflow.Routers.ExamSessions`'s moduledoc and
  `Letflow.Exam.Session.get_session_state_for_user/3`'s own doc reach the
  same conclusion and compensate with a hand-assembled response allowlist
  on the dedicated `GET /exam-sessions/:id` route.

  What neither of those defenses accounts for: `TASK_WORKER` -- this
  codebase's only non-privileged, ordinary-tenant-user role, and the role
  REQ-335 grants every exam-session permission to -- already held
  `:EntitiesQuery`/`:EntitiesAggregate` BEFORE REQ-335 existed. With no
  `entity_field_restrictions` row configured, those pre-existing
  permissions let a TASK_WORKER-scoped caller (an exam candidate) read
  `is_correct` and the other three fields below completely unredacted by
  calling the GENERIC `POST /entities/query`/`POST /entities/query/aggregate`
  routes directly against `question`/`answer_option` -- bypassing
  `get_session_state_for_user/3`'s careful hand-redaction entirely, since
  that redaction only guards ONE route, not the data itself. Confirmed
  empirically in
  `test/letflow/routers/entities_answer_key_field_leak_test.exs`.

  ## What this does NOT change

  `get_session_state_for_user/3`'s own hand-assembled allowlist is left
  exactly as it is -- it stays defense-in-depth (a compile-time-visible
  guarantee, per its own moduledoc, rather than a runtime configuration
  dependency) even once the generic route is also guarded by these rows.
  Neither defense is a substitute for the other.

  ## Callers

  Every place in this codebase that provisions the REAL bilimbaga
  `question`/`answer_option` entity definitions into a tenant schema must
  call `seed_answer_key_field_restrictions!/1`. Two places do:

    - `Letflow.Definitions.SolutionPack.install/3` (the real, production
      `POST /solution-packs/install` path) -- via its private
      `seed_pack_specific_field_restrictions/2` hook inside `run_install/5`,
      conditioned on the installed entity types covering this pack's
      answer-key entity types. This is the fix for the gap this moduledoc
      used to describe as still open: a real tenant installing this pack
      through the live API previously got zero protection, because the only
      caller was the test helper below. See
      `test/letflow/definitions/solution_pack_bilimbaga_field_restrictions_test.exs`
      for the end-to-end regression test proving this path now works
      without any test-only seeding call.
    - `Letflow.ExamFixtures.provisioned_tenant_with_exam_definitions/1`, a
      TEST helper that provisions the same entity definitions directly
      (bypassing `install/3`) for tests that don't need the full pack-install
      flow. This alone is NOT sufficient production protection -- it never
      was; that was the exact gap ISS-0647's rework closed above.
  """

  alias Letflow.Repo

  @typedoc "One `(entity_type, field_name)` pair this pack treats as answer-key data."
  @type restricted_field :: {entity_type :: String.t(), field_name :: String.t()}

  # `question.explanation` (a worked-solution/rationale field) and
  # `answer_option.is_correct`/`likert_weight`/`likert_polarity` -- exactly
  # the four fields `Letflow.Exam.Session.get_session_state_for_user/3`'s own
  # moduledoc names as the ones its hand-assembled response excludes.
  @answer_key_fields [
    {"question", "explanation"},
    {"answer_option", "is_correct"},
    {"answer_option", "likert_weight"},
    {"answer_option", "likert_polarity"}
  ]

  @doc "The `(entity_type, field_name)` pairs this module restricts -- exposed for tests."
  @spec answer_key_fields() :: [restricted_field()]
  def answer_key_fields, do: @answer_key_fields

  @doc """
  Inserts one `entity_field_restrictions` row per `answer_key_fields/0` pair,
  scoped to the tenant schema named by `prefix` -- the same default-deny
  mechanism `Letflow.Entities.Query.FieldGrants` already implements and the
  generic query/aggregate/export routes already redact through (design
  `lib/letflow/design/req231-entity-query-cursor-field-grants.md` §3.2).

  Idempotent: `on_conflict: :nothing` against
  `entity_field_restrictions_entity_type_field_name_idx` (the table's own
  unique index), so calling this more than once against the same tenant
  schema -- or against a schema where a caller already inserted one of these
  exact rows by hand -- is a safe no-op for the rows that already exist.
  """
  @spec seed_answer_key_field_restrictions!(prefix :: String.t()) :: :ok
  def seed_answer_key_field_restrictions!(prefix) when is_binary(prefix) do
    now = NaiveDateTime.utc_now()

    rows =
      Enum.map(@answer_key_fields, fn {entity_type, field_name} ->
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(
      "entity_field_restrictions",
      rows,
      prefix: prefix,
      on_conflict: :nothing,
      conflict_target: [:entity_type, :field_name]
    )

    :ok
  end
end
