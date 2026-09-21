defmodule Letflow.Routers.PlatformMigrations do
  @moduledoc """
  Platform-wide tenant-migration fanout sub-router (REQ-374), mounted at
  `/platform-migrations` directly by `Letflow.Plugs.ApiPipeline` (so full
  paths under `/api/v1` are `/api/v1/platform-migrations/rollouts`,
  `/api/v1/platform-migrations/rollouts/:id`,
  `/api/v1/platform-migrations/rollouts/:id/resume`). See
  `lib/letflow/design/req374-tenant-migration-fanout-runner.md` §7.1 for
  the full design.

  | Handler | Method/path                                  | Domain fn                                | Auth             | Response                                                                    |
  |---------|-----------------------------------------------|-------------------------------------------|------------------|------------------------------------------------------------------------------|
  | start   | `POST /platform-migrations/rollouts`           | `MigrationRollout.start_rollout/3`        | `:TenantsManage` | 200, `rollout_result` map                                                    |
  | status  | `GET /platform-migrations/rollouts/:id`        | `MigrationRollout.rollout_status/1`       | `:TenantsManage` | 200, `%{rollout:, outcomes:}` map; 404 on `:rollout_not_found`               |
  | resume  | `POST /platform-migrations/rollouts/:id/resume`| `MigrationRollout.resume_rollout/1`       | `:TenantsManage` | 200, `rollout_result` map; 404 on `:rollout_not_found`                       |

  `start` responds 200, not 201 — a repeat call returns the same logical
  resource, not a new one (its unique `(entity_type, attribute)` index on
  `platform_migration_rollouts` is the natural key). The response body's
  `rollout.status` and each outcome's `already_current` flag are what
  distinguish a fresh run from a no-op re-run, not the HTTP status code.

  ## Permission decision (design doc §7) — reused, not new: `:TenantsManage`

  All three routes require `:TenantsManage`
  (`Letflow.Api.Authorization`, granted to `PLATFORM_ADMIN` only via the
  existing catch-all `role_allows?(:PLATFORM_ADMIN, _)` clause). Same risk
  class as the two existing precedents that already reuse this exact
  permission for a platform-wide, cross-tenant-touching action outside any
  single tenant's own `:prefix` scope: `POST /tenants` (REQ-075) and
  `POST /onboarding` (REQ-076, moduledoc: "same risk class and same
  PLATFORM_ADMIN-only intent as `Letflow.Routers.Tenants`. No new
  permission added for onboarding."). A platform-wide migration rollout is
  the same shape again — an action with no single tenant context to scope
  by, gated purely on role — so this router follows the same precedent
  rather than adding a fourth permission atom for an identical risk class.
  No new `role_allows?/2` clause is added anywhere by this router.

  No tenant-scoped `:prefix` preamble exists on this router (same
  structural reason `Letflow.Routers.Tenants`/`Letflow.Routers.Onboarding`
  have none): these handlers act across every tenant, so there is no
  single tenant context to scope by. Every handler runs
  `Letflow.Plugs.Authorize` (via `Letflow.Api.AuthorizedRouter`'s fixed
  match/Authorize/dispatch plug chain) before any `Repo` call of any kind.

  ## Request/response JSON shape (design doc §7.1)

  `POST /platform-migrations/rollouts` request body: `%{"entity_type" =>
  string, "attribute" => string, "column_spec" => %{"pg_type" => string,
  "references_entity" => string | nil, "generated_as" => string | nil}}`.
  `nullable` is not caller-supplied — `Letflow.TenantProvisioning.register_column_promotion/4`
  already treats it as always `true` (0023's additive-only rule), so this
  router never accepts it as input; `handle_start/1` fills it in itself
  before calling `MigrationRollout.start_rollout/3`.

  Response bodies serialize `rollout`/`outcome` maps field-for-field as
  named on `Letflow.Platform.MigrationRollout`'s own `rollout()`/`outcome()`
  types, with `tenant_id`/`rollout_id`/timestamps encoded as strings —
  this project's existing JSON convention (see `iso8601/1` below, matching
  `Letflow.Routers.Onboarding`'s own `iso8601/1`).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Platform.MigrationRollout

  authz_post "/rollouts", :TenantsManage do
    handle_start(conn)
  end

  authz_get "/rollouts/:id", :TenantsManage do
    handle_status(conn, conn.params["id"])
  end

  authz_post "/rollouts/:id/resume", :TenantsManage do
    handle_resume(conn, conn.params["id"])
  end

  match _ do
    Response.not_found(conn)
  end

  # ── POST /rollouts ────────────────────────────────────────────────────

  @start_schema [
    %FieldConstraint{
      name: "entity_type",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "attribute",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "column_spec",
      required: true,
      type: :object
    }
  ]

  defp handle_start(conn) do
    case Validation.validate(@start_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"entity_type" => entity_type, "attribute" => attribute, "column_spec" => raw_spec}} ->
        case column_spec_from_request(raw_spec) do
          {:ok, column_spec} ->
            case MigrationRollout.start_rollout(entity_type, attribute, column_spec) do
              {:ok, rollout_result} -> Response.ok(conn, rollout_result_map(rollout_result))
              {:error, :column_spec_conflict} -> Response.conflict(conn, "column_spec conflict")
              {:error, _reason} -> Response.internal_error(conn)
            end

          {:error, message} ->
            Response.bad_request(conn, message)
        end
    end
  end

  # `column_spec.pg_type` is the only structurally-required key beyond
  # what Validation's flat :object check already covers (design doc §7.1
  # names pg_type/references_entity/generated_as as the request's own
  # column_spec keys; `nullable` is never caller-supplied, filled in here,
  # per Letflow.TenantProvisioning.register_column_promotion/4's own
  # "always true, no caller override" contract).
  defp column_spec_from_request(%{"pg_type" => pg_type} = raw_spec)
       when is_binary(pg_type) and pg_type != "" do
    {:ok,
     %{
       pg_type: pg_type,
       nullable: true,
       references_entity: blank_to_nil(Map.get(raw_spec, "references_entity")),
       generated_as: blank_to_nil(Map.get(raw_spec, "generated_as"))
     }}
  end

  defp column_spec_from_request(_raw_spec), do: {:error, "column_spec.pg_type is required"}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value

  # ── GET /rollouts/:id ─────────────────────────────────────────────────

  defp handle_status(conn, id) do
    case MigrationRollout.rollout_status(id) do
      {:ok, rollout_result} -> Response.ok(conn, rollout_result_map(rollout_result))
      {:error, :rollout_not_found} -> Response.not_found(conn)
    end
  end

  # ── POST /rollouts/:id/resume ────────────────────────────────────────

  defp handle_resume(conn, id) do
    case MigrationRollout.resume_rollout(id) do
      {:ok, rollout_result} -> Response.ok(conn, rollout_result_map(rollout_result))
      {:error, :rollout_not_found} -> Response.not_found(conn)
    end
  end

  # ── Response shaping ─────────────────────────────────────────────────

  @doc false
  @spec rollout_result_map(MigrationRollout.rollout_result()) :: map()
  defp rollout_result_map(%{rollout: rollout, outcomes: outcomes}) do
    %{
      "rollout" => rollout_map(rollout),
      "outcomes" => Enum.map(outcomes, &outcome_map/1)
    }
  end

  defp rollout_map(rollout) do
    %{
      "id" => rollout.id,
      "entity_type" => rollout.entity_type,
      "attribute" => rollout.attribute,
      "status" => rollout.status,
      "started_at" => iso8601(rollout.started_at),
      "completed_at" => iso8601(rollout.completed_at)
    }
  end

  defp outcome_map(outcome) do
    %{
      "tenant_id" => outcome.tenant_id,
      "status" => outcome.status,
      "completed_at" => iso8601(outcome.completed_at),
      "reason" => outcome.reason,
      "already_current" => outcome.already_current
    }
  end

  defp iso8601(nil), do: nil

  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
