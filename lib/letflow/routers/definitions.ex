defmodule Letflow.Routers.Definitions do
  @moduledoc """
  Process-definition sub-router, mounted at `/definitions` by
  `Letflow.Plugs.ApiPipeline`.

  REQ-078 adds **exactly one** route to it — the definition-graph validation
  endpoint. The rest of this module's surface is reserved for **REQ-081 and
  REQ-082**, which co-own this file; REQ-078 does not touch the `match _`
  catch-all and modifies no existing route.

  | Handler  | Method/path                    | Delegate                                              | Permission | Response |
  |----------|--------------------------------|-------------------------------------------------------|------------|----------|
  | validate | `POST /definitions/:id/validate` | `Letflow.Definitions.validate_definition_graph/2`    | none in REQ-078 (REQ-131) | 200 valid / 422 findings |

  ## Two different R-Co files are called `validation.zig`. They are unrelated.

    * `src/api/routes/validation.zig` (173 lines) is the **definition-graph
      validation endpoint** — `POST /api/v1/definitions/:id/validate`,
      VLD-01/02/03, which runs validators over a *stored process-definition
      graph*. **That is what is ported here, by REQ-078.**
    * `src/api/validation.zig` (592 lines) is the **request-body validator** —
      API-07, which checks an *incoming JSON request payload* against a
      field-constraint schema and returns RFC 9457 field errors. It has
      nothing to do with process definitions. **That is ported by REQ-068, as
      `Letflow.Api.Validation` (`lib/letflow/api/validation.ex`).**

  Both appear in this module — the second as the `Letflow.Api.Validation`
  calls that check request bodies, the first as this endpoint's own delegate.
  Do not conflate them, and do not "consolidate" them: they validate different
  things at different layers. `Letflow.Api.Validation`'s own moduledoc carries
  a pointer back to this section, so a reader arriving from either side finds
  the distinction.

  ## The `/validation` sub-router stub was DELETED, not left unused

  REQ-070 reserved a `Letflow.Routers.Validation` at `/validation`, grouping
  by Zig **filename** (`routes/validation.zig`) rather than by URL. **R-Co has
  no `/validation` URL prefix anywhere**; the real path is
  `POST /api/v1/definitions/:id/validate` (`main.zig:777-784`,
  `validation.zig:6`), which is a `/definitions` route. Since
  `Plug.Router.forward/2` is prefix-exclusive, two sub-routers cannot both own
  `/definitions`, so a `/validation`-mounted module could never carry R-Co's
  real path. The stub's own moduledoc promised "Routes added by REQ-078", so
  leaving it in place unused would have left behind a module documenting a
  promise it did not keep. It and its forward are gone.

  ## The route adds no validation rule of its own (AC4)

  Everything this handler does after casting `:id` is
  `Letflow.Definitions.validate_definition_graph/2`, which runs exactly
  `Graph.validate_graph/1`, `validate_node_attributes/1` and
  `validate_edge_conditions/1` and concatenates their violations in that
  order. The route contains **no** validation logic, so "the endpoint agrees
  with the validators called directly" is structural, not merely tested.

  `Letflow.Definitions.ServiceScopeValidator.validate/3` is **deliberately
  excluded** — it needs an injected `Lookup.t()` this endpoint has no source
  for, and including it would break that equality.
  `Letflow.Definitions.activate/2` remains its owning path.

  ## `"valid"`, not `"semantically_valid"` — a deliberate divergence

  R-Co emits `"status":"semantically_valid"` plus `"compiler_version"`
  (`validation.zig:115-118`), because its VLD-01/02/03 pipeline performs
  expression type-checking and its VLD-04 gate persists a verdict with a
  compiler version. **Letflow has ported neither.** Claiming
  `"semantically_valid"` would overclaim what was actually checked, and
  `compiler_version` has no value to report. Letflow emits `"valid"` and omits
  `compiler_version`.

  Violations live under a **different key per outcome**, by construction:

  | Outcome | Status | Where violations live |
  |---|---|---|
  | valid   | 200 | `"findings"` — always `[]` |
  | invalid | 422 | `"errors"`, the RFC 9457 extension member |

  A success body is not a problem document and must not carry
  problem-document members.

  ## INV-5 — cross-tenant is 404, and it is the same 404

  An `:id` belonging to another tenant is invisible in the caller's
  prefix-scoped schema, so `get_by_id/2` returns `{:error, :not_found}` — the
  **same call, same code path, same query count and same response bytes** as a
  genuinely absent id. `Letflow.Api.Response.not_found/1` takes no detail, so
  there is no slot through which the two could differ. This matches
  `validation.zig:31`'s own documented behaviour: "cross-tenant reads fall
  through as `DefinitionNotFound` (HTTP 404)". No handler may add a
  cross-tenant existence check to produce a nicer message.

  ## Authorization gap — REQ-131 closes it

  This route does not call `Letflow.Api.Authorization.evaluate_access/2`.
  `endpoint_policy_key/2` has no clause for
  `POST /definitions/:id/validate`, and R-Co's own `authorization.zig` has no
  entry for it either — so there is nothing to port, and deciding what
  permission a definition validation requires is a policy question belonging
  to **REQ-130/REQ-131**. Inventing a route-local permission check here was
  explicitly ruled out. The route is authenticated and tenant-scoped but not
  permission-gated; **REQ-131 is the closer.**

  ## Ordering guarantee

  Honours the contract stated in `Letflow.Routers.Tenants`'s moduledoc section
  **"Ordering guarantee (design §6.1)"**: no `Repo` call of any kind happens
  before the scoped prefix has been resolved. Structural here — **this module
  performs no `Repo` call at all**; the one read is inside
  `Letflow.Definitions.validate_definition_graph/2`, whose `opts` argument
  *is* the prefix.
  """

  use Plug.Router

  alias Letflow.Api.Context
  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Definitions
  alias Letflow.Definitions.Graph

  plug(:match)
  plug(:dispatch)

  post "/:id/validate" do
    handle_validate(conn, conn.params["id"])
  end

  match _ do
    Response.not_found(conn)
  end

  # ── POST /definitions/:id/validate (design §7) ────────────────────────────
  #
  # Bodyless, like Letflow.Routers.Tenants's deactivate/reactivate:
  # `conn.body_params` is ignored. R-Co's handleValidate takes no body either
  # (validation.zig:75-80).

  defp handle_validate(conn, raw_id) do
    with {:ok, id} <- cast_id(raw_id),
         {:ok, opts} <- scoped_repo_opts(conn) do
      render_validation(conn, Definitions.validate_definition_graph(id, opts))
    else
      {:error, :invalid_id_format} -> Response.unprocessable(conn, "invalid id format")
      {:error, :missing_scope} -> Response.internal_error(conn)
    end
  end

  defp render_validation(conn, {:ok, %{valid: true, definition_id: definition_id}}) do
    Response.ok(conn, %{
      "status" => "valid",
      "findings" => [],
      "definition_id" => definition_id,
      "validated_at" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp render_validation(conn, {:ok, %{valid: false, violations: violations}}) do
    # The constructor-then-override idiom Letflow.Api.Validation.problem/1
    # already uses: `@problems_base` is a PRIVATE compile-env attribute on
    # Letflow.Api.Error and is not referenceable from here, so the `type`
    # field cannot be written literally -- it must come from the constructor.
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("definition graph failed validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  # INV-5: absent and another tenant's are the same bytes because they are the
  # same call.
  defp render_validation(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp render_validation(conn, {:error, :graph_structure_invalid}),
    do: Response.unprocessable(conn, "definition graph is not well-formed")

  # {:error, :invalid_schema_name} / {:error, {:transaction_failed, _}}.
  # No 503 branch -- Ecto surfaces pool exhaustion as a raised
  # DBConnection.ConnectionError, never an error tuple.
  defp render_validation(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Checked in the route before any call, matching validation.zig:83-85.
  defp cast_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id_format}
    end
  end

  defp scoped_repo_opts(conn) do
    case Context.scoped_repo_opts(conn) do
      {:ok, opts} -> {:ok, opts}
      {:error, _missing_auth_context_or_invalid_tenant_id} -> {:error, :missing_scope}
    end
  end

  # Total, not a redaction: %Graph.Violation{} has exactly two fields.
  # Letflow.Api.Error.serialise/1's `errors: [_ | _]` clause passes the list
  # straight to Jason.encode!/1, so these must already be plain string-keyed
  # maps -- never %Violation{} structs.
  @spec violation_map(Graph.Violation.t()) :: map()
  defp violation_map(%Graph.Violation{code: code, message: message}) do
    %{"code" => Atom.to_string(code), "message" => message}
  end
end
