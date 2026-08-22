defmodule Letflow.Routers.Definitions do
  @moduledoc """
  Process-definition sub-router, mounted at `/definitions` by
  `Letflow.Plugs.ApiPipeline`.

  REQ-078 adds **exactly one** route to it — the definition-graph validation
  endpoint. REQ-081 adds the five read routes below. The rest of this
  module's surface (create/update/patch/activate/deprecate/archive/import) is
  reserved for **REQ-082**, which co-owns this file; neither REQ-078 nor
  REQ-081 touches the `match _` catch-all or modifies an existing route.

  | Handler               | Method/path                       | Delegate                                              | Permission        | Response |
  |------------------------|-----------------------------------|--------------------------------------------------------|-------------------|----------|
  | validate               | `POST /definitions/:id/validate`  | `Letflow.Definitions.validate_definition_graph/2`       | none in REQ-078 (REQ-131) | 200 valid / 422 findings |
  | get_active_by_name     | `GET /definitions/active/:name`   | `Letflow.Definitions.get_active_by_name/2`              | `DefinitionsRead` | 200 / 404 |
  | search                 | `GET /definitions/search`         | `Letflow.Definitions.search_paginated/3`                | `DefinitionsRead` | 200 / 400 |
  | export                 | `GET /definitions/:id/export`     | `Letflow.Definitions.ExportImport.export/2`             | `DefinitionsRead` | 200 / 404 |
  | get_by_id              | `GET /definitions/:id`            | `Letflow.Definitions.get_by_id/2`                       | `DefinitionsRead` | 200 / 404 |
  | list                   | `GET /definitions`                | `Letflow.Definitions.list_paginated/2`                  | `DefinitionsRead` | 200 |

  ## REQ-081 — read routes (design: `lib/letflow/design/req081-definition-routes-read.md`)

  Five `GET` handlers, all delegating into `Letflow.Definitions`/
  `Letflow.Definitions.ExportImport` (both already shipped, except
  `list_paginated/2`/`search_paginated/3` which REQ-081 adds). Every one is
  wrapped in `with_authorized_scope/4`, copied structurally from
  `Letflow.Routers.Instances`'s own private helper of the same name and
  shape (temporary direct duplication, pending REQ-131's consolidation —
  same precedent, not a shared/imported module).

  ### Route ordering

  `/active/:name`, `/search`, and `/:id/export` are declared **above**
  `/:id`, which is declared above `/`, matching R-Co's own registration
  order (`main.zig`) and the same hazard class `Letflow.Routers.Instances`'s
  `/:id/history`-before-`/:id` note documents: `Plug.Router` is first-match-
  wins, so a bare `GET "/:id"` declared above any of the three would swallow
  it with `id` bound to the literal suffix.

  ### `handle_search`'s three-way HTTP contract (AC2/AC3)

  `Definitions.search_paginated/3` returns `{:error, :query_empty}`/
  `{:error, :query_too_long}` for a validation failure (mapped to **400**,
  matching REQ-081's acceptance criteria text verbatim — a deliberate
  divergence from R-Co's own 422 for both), and a genuinely-valid,
  zero-match query returns `{:ok, %{items: [], next_cursor: nil}}` (**200**,
  empty array) — never conflated. `render_search_result/1`'s clause list
  keeps these as three separate code paths.

  ### `get_by_id`/`export` inherit `get_by_id/2`'s not-found collapse (OQ-2)

  Neither handler pre-casts `:id` to a UUID the way `Letflow.Routers.Instances`
  does for `instance_id` — `Letflow.Definitions.get_by_id/2` (REQ-030) already
  internally maps a cast failure to `{:error, :not_found}` (its own
  `cast_uuid/1`), so a malformed UUID and a genuinely-absent-but-well-formed
  UUID collapse to the same 404. This is a **stronger** INV-5 guarantee than
  R-Co's own 422-vs-404 split, flagged in the design doc for REVIEWER
  sign-off rather than silently decided.

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

  alias Letflow.Api.Authorization
  alias Letflow.Api.Context
  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Definitions
  alias Letflow.Definitions.ExportImport
  alias Letflow.Definitions.ExportImport.ExportDocument
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition

  plug(:match)
  plug(:dispatch)

  # REQ-081 read routes. MUST precede `get "/:id"` below -- see this
  # module's moduledoc "Route ordering".
  get "/active/:name" do
    handle_get_active_by_name(conn, conn.params["name"])
  end

  get "/search" do
    handle_search(conn)
  end

  get "/:id/export" do
    handle_export(conn, conn.params["id"])
  end

  get "/:id" do
    handle_get_by_id(conn, conn.params["id"])
  end

  get "/" do
    handle_list(conn)
  end

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

  # ── GET /definitions/:id (design §4.3) ─────────────────────────────────
  #
  # No pre-cast of `:id` -- see this module's moduledoc "get_by_id/export
  # inherit get_by_id/2's not-found collapse (OQ-2)".

  defp handle_get_by_id(conn, raw_id) do
    with_authorized_scope(conn, "GET", "/definitions/:id", fn conn, opts ->
      render_get_by_id(conn, Definitions.get_by_id(raw_id, opts))
    end)
  end

  defp render_get_by_id(conn, {:ok, definition}),
    do: Response.ok(conn, definition_map(definition))

  defp render_get_by_id(conn, {:error, :not_found}), do: Response.not_found(conn)
  defp render_get_by_id(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── GET /definitions (design §4.3) ─────────────────────────────────────

  defp handle_list(conn) do
    with_authorized_scope(conn, "GET", "/definitions", fn conn, opts ->
      conn = fetch_query_params(conn)
      query = conn.query_params

      with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
           {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
        filters = %{
          name: Map.get(query, "name"),
          status: parse_status(Map.get(query, "status")),
          stage: Map.get(query, "stage"),
          cursor: Map.get(query, "cursor"),
          page_size: page_size
        }

        render_list_result(conn, Definitions.list_paginated(filters, opts))
      else
        {:error, :invalid_page_size} -> Response.bad_request(conn, "invalid page_size")
        {:error, :page_size_too_large} -> Response.bad_request(conn, "page_size out of range")
      end
    end)
  end

  # `status` is compared against ProcessDefinition.status/0's lowercase atoms
  # inside Definitions.list_paginated/2's where_status/2 (unchanged, existing
  # helper) -- absent/unrecognised values pass through as a plain lowercased
  # string/atom-cast attempt is deliberately NOT done here: where_status/2
  # itself does a plain `==` comparison against the stored (already-atom)
  # column, so an unrecognised string simply matches no rows rather than
  # raising, matching this module's existing no-extra-validation-layer style.
  defp parse_status(nil), do: nil

  defp parse_status(status) when is_binary(status) do
    status |> String.downcase() |> safe_to_existing_atom()
  end

  defp safe_to_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp render_list_result(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &definition_map/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_list_result(conn, {:error, :invalid_cursor}),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_list_result(conn, {:error, :wrong_endpoint}),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  defp render_list_result(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp render_list_result(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── GET /definitions/active/:name (design §4.3) ────────────────────────

  defp handle_get_active_by_name(conn, name) do
    with_authorized_scope(conn, "GET", "/definitions/active/:name", fn conn, opts ->
      render_get_by_id(conn, Definitions.get_active_by_name(name, opts))
    end)
  end

  # ── GET /definitions/search (design §4.4 -- the requirement's stated trap) ──

  defp handle_search(conn) do
    with_authorized_scope(conn, "GET", "/definitions/search", fn conn, opts ->
      conn = fetch_query_params(conn)
      query = conn.query_params

      with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
           {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
        q = Map.get(query, "q") || ""
        params = %{cursor: Map.get(query, "cursor"), page_size: page_size}

        render_search_result(conn, Definitions.search_paginated(q, params, opts))
      else
        {:error, :invalid_page_size} -> Response.bad_request(conn, "invalid page_size")
        {:error, :page_size_too_large} -> Response.bad_request(conn, "page_size out of range")
      end
    end)
  end

  # Five clauses, one per outcome -- query_empty/query_too_long are
  # validation failures (400), never routed through the {:ok, ...} clause's
  # empty-array path and never mapped to 404. See this module's moduledoc.
  defp render_search_result(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &search_result_map/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_search_result(conn, {:error, :query_empty}),
    do: Response.bad_request(conn, "q must not be empty")

  defp render_search_result(conn, {:error, :query_too_long}),
    do: Response.bad_request(conn, "q must not exceed 512 bytes")

  defp render_search_result(conn, {:error, :invalid_cursor}),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_search_result(conn, {:error, :wrong_endpoint}),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  # REVIEWER fix (WF02-REQ081): use the dedicated cursor-expired problem
  # type, matching handle_list's own :expired clause above and
  # Letflow.Routers.Instances's established idiom -- a plain bad_request/2
  # here (as the design doc's §4.4 prose literally read) would give this
  # error condition a different wire-level `type` than every other
  # cursor-expired response in the API, for no reason.
  defp render_search_result(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp render_search_result(conn, {:error, _common_error}), do: Response.internal_error(conn)

  defp search_result_map(%{definition: definition, rank: rank}) do
    %{"definition" => definition_map(definition), "rank" => rank}
  end

  # ── GET /definitions/:id/export (design §4.3) ──────────────────────────
  #
  # No pre-cast of `:id` -- same OQ-2 rationale as handle_get_by_id/2, since
  # ExportImport.export/2 delegates its own read entirely to
  # Definitions.get_by_id/2.

  defp handle_export(conn, raw_id) do
    with_authorized_scope(conn, "GET", "/definitions/:id/export", fn conn, opts ->
      render_export(conn, ExportImport.export(raw_id, opts))
    end)
  end

  defp render_export(conn, {:ok, document}), do: Response.ok(conn, export_document_map(document))
  defp render_export(conn, {:error, :not_found}), do: Response.not_found(conn)
  defp render_export(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── Response allowlists (INV-2, design §6) ─────────────────────────────

  @spec definition_map(ProcessDefinition.t()) :: map()
  defp definition_map(%ProcessDefinition{} = definition) do
    %{
      "id" => definition.id,
      "name" => definition.name,
      "version" => definition.version,
      "description" => definition.description,
      "status" => status_string(definition.status),
      "graph" => definition.graph,
      "created_by" => definition.created_by,
      "created_at" => DateTime.to_iso8601(definition.created_at),
      "updated_at" => DateTime.to_iso8601(definition.updated_at),
      "archived_at" => optional_iso8601(definition.archived_at),
      "stage" => definition.stage
    }
  end

  @spec export_document_map(ExportDocument.t()) :: map()
  defp export_document_map(%ExportDocument{} = document) do
    %{
      "bpm_export_schema_version" => document.bpm_export_schema_version,
      "id" => document.id,
      "name" => document.name,
      "version" => document.version,
      "description" => document.description,
      "graph" => document.graph,
      "exported_at" => document.exported_at
    }
  end

  defp optional_iso8601(nil), do: nil
  defp optional_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp status_string(:draft), do: "DRAFT"
  defp status_string(:active), do: "ACTIVE"
  defp status_string(:deprecated), do: "DEPRECATED"
  defp status_string(:archived), do: "ARCHIVED"

  # ── Authorization (temporary direct call, pending REQ-131) ────────────────
  #
  # Copied structurally from Letflow.Routers.Instances's own
  # with_authorized_scope/4 -- see this module's moduledoc "REQ-081 -- read
  # routes". No Repo call of any kind happens before both steps (scope, then
  # permission) have run and the permission check has returned
  # :Allow/:AllowWithRowFilter. Unlike Instances's version this one has no
  # actor_id to thread through (none of the five REQ-081 handlers need one),
  # so `fun` is arity 2 (`conn`, `opts`), not arity 3.
  defp with_authorized_scope(conn, method, path_template, fun) do
    case scoped_repo_opts(conn) do
      {:ok, opts} ->
        case actor_id(conn) do
          {:ok, actor_id} ->
            ctx = %Authorization.AccessContext{
              user_id: actor_id,
              roles: Authorization.roles_from_strings(conn.assigns.auth_context.roles)
            }

            decision =
              Authorization.evaluate_access(
                ctx,
                Authorization.endpoint_policy_key(method, path_template)
              )

            case decision.kind do
              :Deny403 -> Response.forbidden(conn, "insufficient permissions")
              _allow_or_allow_with_row_filter -> fun.(conn, opts)
            end

          {:error, :missing_scope} ->
            Response.internal_error(conn)
        end

      {:error, :missing_scope} ->
        Response.internal_error(conn)
    end
  end

  defp actor_id(conn) do
    case conn.assigns[:auth_context] do
      %{user_id: user_id} when is_binary(user_id) -> {:ok, user_id}
      _other -> {:error, :missing_scope}
    end
  end

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
