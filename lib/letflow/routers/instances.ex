defmodule Letflow.Routers.Instances do
  @moduledoc """
  Process-instance sub-router, mounted at `/instances` by
  `Letflow.Plugs.ApiPipeline`.

  REQ-078 added the explicit pin-rebind endpoint (PIN-05). REQ-079 adds the
  three write routes below (create/cancel/reconstruct). REQ-080 (read routes,
  `GET`) still co-owns this file; REQ-079 does not touch the `match _`
  catch-all and modifies no existing route.

  | Handler     | Method/path                        | Delegate                                                              | Permission | Response |
  |-------------|-------------------------------------|-------------------------------------------------------------------------|------------|----------|
  | rebind      | `POST /instances/:id/rebind-pins`  | `Letflow.Engine.PinRebind.rebind_pins/3`                                | none in REQ-078 (REQ-131) | 200, `{instance_id, changes, rebound_at}` |
  | create      | `POST /instances`                  | `Letflow.Engine.create/2`                                               | `InstancesStart` | 201, `{instance_id, status, created_at}` |
  | cancel      | `POST /instances/:id/cancel`       | `Letflow.Engine.cancel_instance/3`                                      | `InstancesCancel` | 200, `{instance_id, status}`; 409 if already `COMPLETED` or already `CANCELLED` |
  | reconstruct | `POST /instances/:id/reconstruct`  | `Letflow.Engine.Reconstruction.reconstruct_instance/2` (`write_back: true`, not caller-controllable) | none (REQ-079 — same precedent as rebind, a future policy decision) | 200, `{instance_id, status, tokens: [{node_id, branch_id}], variables}` |

  ## Route ordering — `rebind-pins`/`cancel`/`reconstruct` MUST precede any future `POST /instances/:id`

  R-Co's own registration carries the same constraint verbatim
  (`src/main.zig:848`: "must precede plain /:id"). `Plug.Router` matches in
  declaration order, so a `post "/:id"` declared **above** these three would
  swallow all of them. `/:id/cancel` and `/:id/reconstruct` are literal path
  suffixes distinct from `/:id/rebind-pins` and from each other, so they do
  not compete with one another regardless of relative order — but no bare
  `POST "/:id"` may be declared above any of the three. **REQ-080: `GET` and
  `POST` are independent dispatch tables in `Plug.Router`, so this constraint
  does not extend to REQ-080's read routes.**

  ## `POST /instances` — definition_id vs definition_name

  `definition_id`/`definition_name` mutual exclusivity is enforced by
  `Letflow.Engine.create/2` itself (`:missing_definition_reference` /
  `:both_definition_id_and_name`), not by `@create_schema` —
  `Letflow.Api.Validation.FieldConstraint` has no cross-field vocabulary, the
  same reasoning `normalise_entries/1` below already gives for per-element
  checks it can't express. `definition_name` is a Letflow addition over R-Co
  (REQ-045) exposed here because `Letflow.Engine.create/2` already accepts
  it — restricting this route to `definition_id` only would regress an
  already-shipped capability. `create_attrs/2` drops a `nil`-valued
  `definition_id`/`definition_name`/`correlation_key` rather than passing an
  explicit-`null` key through, so an explicit JSON `null` and an absent key
  are indistinguishable to `Engine.create/2`'s own XOR check either way.

  ## Cancelling a terminal instance is 409, not 404 or 500

  Both already-`COMPLETED` and already-`CANCELLED` map to 409, with a
  per-status detail string (AC6) — a considered choice, not an inconsistency
  with `render_rebind/2`'s constant-detail precedent (that precedent is about
  not leaking *internal* detail, not about collapsing two equally-valid
  terminal states into one message). An `:error`-status instance is **not**
  terminal (`Letflow.EventStore.InstanceProjection.terminal?/1` only returns
  `true` for `:completed`/`:cancelled`) — cancelling one succeeds (200), same
  as an `:active` instance.

  ## Reconstruct always write-backs, and has no route-local permission check

  `write_back: true` is hardcoded, not a request option, matching R-Co's
  `handleReconstruct` exactly. No `endpoint_policy_key/2` clause exists for
  this route, and neither does R-Co's own `authorization.zig` (confirmed by
  grep, zero hits) — same precedent as rebind-pins: authenticated +
  tenant-scoped only, not permission-gated. A future permission requirement
  is a REQ-131-class policy decision, not this requirement's to invent.

  ## No separate `Letflow.Routers.PinRebind`

  `Plug.Router.forward/2` is prefix-exclusive, so a separate sub-router could
  not be mounted at `/instances`; giving pin rebind its own sub-router would
  have forced an invented URL. It is an instances route and it lives on the
  instances router.

  ## Idempotency-key convention — the FIRST in this codebase (REQ-079/080 must adopt it)

  `Letflow.Engine.PinRebind.rebind_attrs()` **requires** `:idempotency_key`.
  R-Co's request body has none (`pin_rebind.zig:26-30`), so the route must
  source one, and no other Letflow router reads an idempotency header —
  `grep -rn "Idempotency-Key\|idempotency_key" lib/letflow/api/ lib/letflow/routers/`
  returned zero hits before REQ-078.

  **The convention: read the `idempotency-key` request header; if present and
  non-empty, use it truncated to 255 bytes; otherwise generate
  `Ecto.UUID.generate/0`.**

  This is the first HTTP-layer idempotency convention in this codebase.
  **REQ-079 and REQ-080 must adopt this same convention rather than inventing
  a second one.** If a different shape is wanted, change it here and change
  every adopter in the same commit — two disagreeing conventions for the same
  header is the failure mode this sentence exists to prevent.

  ## INV-5 — cross-tenant is 404, and it is the same 404

  An instance belonging to another tenant is invisible in the caller's
  prefix-scoped schema, so `rebind_pins/3` returns
  `{:error, :instance_not_found}` — the **same call, same code path and same
  response bytes** as a genuinely absent instance.
  `Letflow.Api.Response.not_found/1` takes no detail, so there is no slot
  through which the two could differ. No handler may add a cross-tenant
  existence check to produce a nicer message.

  ## Response shape

  `changes` maps `rebind_result().changed` element-wise into hand-built
  four-key maps (INV-2), with `kind` rendered via `Atom.to_string/1`.
  `rebound_at` has **no R-Co counterpart** — it is a Letflow addition, carried
  because `rebind_result()` already returns it and it is useful to a caller
  correlating the rebind with the `INSTANCE_PINS_REBOUND` event.

  The request's `kind` values are passed through as **raw strings**;
  `rebind_attrs()` explicitly permits `String.t()`, so no atom conversion
  happens in this route and therefore no attacker-controlled atom is ever
  created.

  ## Deliberate non-port

  **503 `PoolExhausted`** — Ecto/DBConnection surfaces pool exhaustion as a
  raised `DBConnection.ConnectionError`, not an error tuple, so a 503 clause
  would be a branch nothing can reach.

  ## Authorization gap — REQ-131 closes it

  This route does not call `Letflow.Api.Authorization.evaluate_access/2`.
  `endpoint_policy_key/2` has no clause for
  `POST /instances/:id/rebind-pins`, and R-Co's own `authorization.zig` has no
  entry for it either — so there is nothing to port, and deciding what
  permission a pin rebind requires is a policy question belonging to
  **REQ-130/REQ-131**. Inventing a route-local permission check here was
  explicitly ruled out. The route is authenticated and tenant-scoped but not
  permission-gated; **REQ-131 is the closer.**

  ## Ordering guarantee

  Honours the contract stated in `Letflow.Routers.Tenants`'s moduledoc section
  **"Ordering guarantee (design §6.1)"**: no `Repo` call of any kind happens
  before the scoped prefix has been resolved. Structural here — **this module
  performs no `Repo` call at all**; every read, lock and append is inside
  `Letflow.Engine.PinRebind.rebind_pins/3`, whose `opts` argument *is* the
  prefix.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Context
  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Engine
  alias Letflow.Engine.PinRebind
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.Reconstruction
  alias Letflow.Instances

  @idempotency_key_header "idempotency-key"
  @max_idempotency_key_bytes 255

  # Letflow.Engine.PinResolver.kind() rendered as the three strings R-Co's
  # parsePinKind accepts (pin_rebind.zig:165-170).
  @pin_kinds ["catalog_entry", "variable_schema", "module"]

  # MUST precede any future `post "/:id"` -- see this module's moduledoc.
  #
  # REQ-131: no endpoint_policy_key/2 clause exists for this route (see
  # "Authorization gap" below) -- :InstancesCancel is a route-declared
  # policy key, reusing the same permission POST /:id/cancel already
  # requires (both mutate an in-flight instance's execution state), NOT
  # derived from Authorization.endpoint_policy_key/2. Named on the
  # enforcement test's explicit allowlist (design §4) -- flagged for
  # REVIEWER as a judgment call, not silently decided.
  authz_post "/:id/rebind-pins", :InstancesCancel do
    handle_rebind_pins(conn, conn.params["id"])
  end

  authz_post "/:id/cancel", :InstancesCancel do
    handle_cancel(conn, conn.params["id"])
  end

  # REQ-131: same judgment call as /:id/rebind-pins above -- see that
  # route's comment and the enforcement test's allowlist.
  authz_post "/:id/reconstruct", :InstancesCancel do
    handle_reconstruct(conn, conn.params["id"])
  end

  authz_post "/", :InstancesStart do
    handle_create(conn)
  end

  # REQ-080 read routes. MUST precede `get "/:id"` below -- same hazard
  # class Letflow.Routers.Tasks's `/inbox`-before-`/:id` note documents;
  # `Plug.Router` first-match-wins would otherwise have `/:id` swallow each
  # of these with `id` bound to the literal suffix.
  authz_get "/:id/history", :InstancesRead do
    handle_history(conn, conn.params["id"])
  end

  authz_get "/:id/timeline", :InstancesRead do
    handle_timeline(conn, conn.params["id"])
  end

  authz_get "/:id/pins", :InstancesRead do
    handle_get_pins(conn, conn.params["id"])
  end

  authz_get "/:id", :InstancesRead do
    handle_get_by_id(conn, conn.params["id"])
  end

  authz_get "/", :InstancesRead do
    handle_list(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── POST /instances/:id/rebind-pins (design §10) ──────────────────────────

  @rebind_schema [
    %FieldConstraint{
      name: "reason",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 1024
    },
    %FieldConstraint{
      name: "entries",
      required: true,
      type: :array,
      min_items: 1
    }
  ]

  defp handle_rebind_pins(conn, raw_id) do
    with {:ok, body} <- object_body(conn),
         {:ok, instance_id} <- cast_instance_id(raw_id),
         {:ok, attrs} <- validate_body(body),
         {:ok, entries} <- normalise_entries(Map.get(attrs, "entries")),
         {:ok, opts} <- scoped_repo_opts(conn),
         {:ok, actor_id} <- actor_id(conn) do
      rebind_attrs = %{
        entries: entries,
        reason: Map.get(attrs, "reason"),
        actor_id: actor_id,
        idempotency_key: idempotency_key(conn)
      }

      render_rebind(conn, PinRebind.rebind_pins(instance_id, rebind_attrs, opts))
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :invalid_input} ->
        Response.unprocessable(conn, "request body failed validation")

      {:error, :missing_scope_or_actor} ->
        Response.internal_error(conn)
    end
  end

  defp render_rebind(conn, {:ok, result}), do: Response.ok(conn, rebind_result_map(result))

  defp render_rebind(conn, {:error, :instance_not_found}), do: Response.not_found(conn)

  # `_status` is deliberately NOT echoed: the constant detail keeps the body
  # stable across statuses.
  defp render_rebind(conn, {:error, {:instance_not_rebindable, _status}}),
    do: Response.conflict(conn, "instance is in a terminal state and cannot be rebound")

  defp render_rebind(conn, {:error, {:concurrent_modification, _instance_id}}),
    do: Response.conflict(conn, "instance is locked by another transaction")

  # Neither `kind` nor `ref` is echoed. Both are caller-supplied so echoing
  # would be safe, but a constant detail matches Letflow.Routers.Tenants's
  # established constant-detail style.
  defp render_rebind(conn, {:error, {:unknown_pin_ref, _kind, _ref}}),
    do:
      Response.unprocessable(
        conn,
        "a requested entry is not present in the instance's current effective pin set"
      )

  defp render_rebind(conn, {:error, :invalid_instance_id}),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp render_rebind(conn, {:error, reason})
       when reason in [:invalid_reason, :empty_entries],
       do: Response.unprocessable(conn, "request body failed validation")

  defp render_rebind(conn, {:error, {:malformed_entry, _index, _reason}}),
    do: Response.unprocessable(conn, "request body failed validation")

  # All route-construction bugs, not caller errors: INV-4's no-detail 500.
  # {:event_append_failed, _}, %Ecto.Changeset{} and any other term land here
  # too. No 503 branch -- see the moduledoc.
  defp render_rebind(conn, {:error, _internal}), do: Response.internal_error(conn)

  # ── POST /instances (design §"Routes"/create) ─────────────────────────────

  @create_schema [
    %FieldConstraint{name: "definition_id", required: false, type: :uuid},
    %FieldConstraint{
      name: "definition_name",
      required: false,
      type: :string,
      reject_empty_string: true
    },
    %FieldConstraint{name: "correlation_key", required: false, type: :string},
    %FieldConstraint{name: "initial_variables", required: true, type: :object}
  ]

  defp handle_create(conn) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@create_schema, body) do
      create_attrs = create_attrs(attrs, actor_id, idempotency_key(conn))
      render_create(conn, Engine.create(create_attrs, opts))
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # Only includes keys the request actually sent (never a nil-valued key),
  # so a caller who supplied neither/both of definition_id/definition_name
  # still reaches Engine.create/2's own XOR check rather than being masked
  # by a nil key -- see this module's moduledoc.
  defp create_attrs(attrs, actor_id, idempotency_key) do
    %{
      initial_variables: Map.fetch!(attrs, "initial_variables"),
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }
    |> maybe_put(:definition_id, Map.get(attrs, "definition_id"))
    |> maybe_put(:definition_name, Map.get(attrs, "definition_name"))
    |> maybe_put(:correlation_key, Map.get(attrs, "correlation_key"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp render_create(conn, {:ok, result}) do
    Response.created(conn, %{
      "instance_id" => result.instance_id,
      "status" => status_string(result.status),
      "created_at" => DateTime.to_iso8601(result.started_at)
    })
  end

  defp render_create(conn, {:error, reason})
       when reason in [:missing_definition_reference, :both_definition_id_and_name],
       do:
         Response.unprocessable(
           conn,
           "exactly one of definition_id or definition_name is required"
         )

  # :tenant_id_not_accepted and :invalid_initial_variables are unreachable via
  # this route (create_attrs/2 never produces a :tenant_id key; @create_schema
  # gates initial_variables' type before Engine.create/2 ever runs) -- mapped
  # anyway for completeness/defence-in-depth, same style as the moduledoc's
  # other unreachable-but-mapped rows.
  defp render_create(conn, {:error, reason})
       when reason in [:tenant_id_not_accepted, :invalid_initial_variables],
       do: Response.unprocessable(conn, "request body failed validation")

  defp render_create(conn, {:error, :definition_not_found}), do: Response.not_found(conn)

  defp render_create(conn, {:error, :definition_not_active}),
    do: Response.conflict(conn, "only an ACTIVE definition can be started")

  defp render_create(conn, {:error, :duplicate_correlation_key}),
    do:
      Response.conflict(
        conn,
        "an active instance with this correlation key already exists"
      )

  defp render_create(conn, {:error, {tag, _detail}})
       when tag in [
              :unresolved_catalog_ref,
              :unresolved_module_ref,
              :unresolved_pin_override,
              :variable_schema_violation
            ],
       do: Response.unprocessable(conn, "request body failed validation")

  # {:snapshot_failed, _}, {:graph_structure_invalid, _}, {:activation_failed,
  # _}, {:event_append_failed, _}, {:parent_pin_lookup_failed, _},
  # %Ecto.Changeset{}, :invalid_schema_name, and any other term: INV-4's
  # no-detail 500. No 503 branch -- see the moduledoc.
  defp render_create(conn, {:error, _internal}), do: Response.internal_error(conn)

  # ── POST /instances/:id/cancel (design §"Routes"/cancel) ──────────────────

  defp handle_cancel(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    case cast_instance_id(raw_id) do
      {:ok, instance_id} ->
        cancel_attrs = %{actor_id: actor_id, idempotency_key: idempotency_key(conn)}
        render_cancel(conn, Engine.cancel_instance(instance_id, cancel_attrs, opts))

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")
    end
  end

  defp render_cancel(conn, {:ok, result}) do
    Response.ok(conn, %{"instance_id" => result.instance_id, "status" => "CANCELLED"})
  end

  defp render_cancel(conn, {:error, :invalid_instance_id}),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp render_cancel(conn, {:error, :instance_not_found}), do: Response.not_found(conn)

  # Distinct detail strings per terminal status (AC6) -- both states are
  # equally caller-meaningful, unlike render_rebind/2's constant-detail
  # precedent, which is about not leaking *internal* detail.
  defp render_cancel(conn, {:error, {:instance_already_terminal, :completed}}),
    do: Response.conflict(conn, "instance is already completed and cannot be cancelled")

  defp render_cancel(conn, {:error, {:instance_already_terminal, :cancelled}}),
    do: Response.conflict(conn, "instance is already cancelled")

  # {:event_append_failed, _}, %Ecto.Changeset{}, :missing_actor_id,
  # :missing_idempotency_key, :invalid_schema_name, and any other term:
  # INV-4's no-detail 500. The last three are route-unreachable (actor_id and
  # idempotency_key are always sourced by this handler, never absent; the
  # schema name is resolved from the authenticated tenant_id, never
  # caller-supplied) -- see the moduledoc.
  defp render_cancel(conn, {:error, _internal}), do: Response.internal_error(conn)

  # ── POST /instances/:id/reconstruct (design §"Routes"/reconstruct) ────────
  #
  # No endpoint_policy_key/2 clause exists for this route -- see the
  # moduledoc. Authenticated + tenant-scoped only, matching REQ-078's
  # rebind-pins precedent.
  defp handle_reconstruct(conn, raw_id) do
    case scoped_repo_opts(conn) do
      {:ok, opts} ->
        case cast_instance_id(raw_id) do
          {:ok, instance_id} ->
            render_reconstruct(
              conn,
              Reconstruction.reconstruct_instance(
                instance_id,
                Keyword.put(opts, :write_back, true)
              )
            )

          {:error, :invalid_instance_id} ->
            Response.unprocessable(conn, "instance_id is not a valid UUID")
        end

      {:error, :missing_scope_or_actor} ->
        Response.internal_error(conn)
    end
  end

  defp render_reconstruct(conn, {:ok, result}) do
    state = result.instance_state

    Response.ok(conn, %{
      "instance_id" => result.instance_id,
      "status" => status_string(state.status),
      "tokens" => Enum.map(state.tokens, &token_map/1),
      "variables" => state.variables
    })
  end

  defp render_reconstruct(conn, {:error, :invalid_instance_id}),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp render_reconstruct(conn, {:error, :instance_not_found}), do: Response.not_found(conn)

  defp render_reconstruct(conn, {:error, {:lock_contention, _instance_id}}),
    do: Response.conflict(conn, "instance is locked by another transaction")

  # {:replay_failed, _}, :invalid_schema_name, and any other term: INV-4's
  # no-detail 500. No 503 branch -- see the moduledoc.
  defp render_reconstruct(conn, {:error, _internal}), do: Response.internal_error(conn)

  defp token_map(token), do: %{"node_id" => token.node_id, "branch_id" => token.branch_id}

  # ── GET /instances/:id (design §"Router"/get_by_id) ────────────────────

  defp handle_get_by_id(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    case cast_instance_id(raw_id) do
      {:ok, id} ->
        render_get_by_id(conn, Instances.get_by_id(id, opts))

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")
    end
  end

  defp render_get_by_id(conn, {:ok, projection}), do: Response.ok(conn, instance_map(projection))
  defp render_get_by_id(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp render_get_by_id(conn, {:error, :invalid_id}),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp instance_map(projection) do
    %{
      "instance_id" => projection.instance_id,
      "definition_id" => projection.definition_id,
      "correlation_key" => projection.correlation_key,
      "status" => status_string(projection.status),
      "variables" => projection.variables,
      "started_at" => DateTime.to_iso8601(projection.started_at),
      "completed_at" => optional_iso8601(projection.completed_at),
      "cancelled_at" => optional_iso8601(projection.cancelled_at),
      "error_detail" => projection.error_detail
    }
  end

  defp optional_iso8601(nil), do: nil
  defp optional_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ── GET /instances (design §"Router"/list) ──────────────────────────────

  defp handle_list(conn) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, started_after} <- parse_optional_timestamp(Map.get(query, "started_after")),
         {:ok, started_before} <- parse_optional_timestamp(Map.get(query, "started_before")) do
      params = %{
        status: Map.get(query, "status"),
        definition_id: Map.get(query, "definition_id"),
        correlation_key: Map.get(query, "correlation_key"),
        started_after: started_after,
        started_before: started_before,
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      Instances.list(params, opts) |> render_page_result(conn, &list_item_map/1)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_timestamp} ->
        Response.unprocessable(
          conn,
          "started_after/started_before must be valid ISO 8601 timestamps"
        )
    end
  end

  defp list_item_map(projection) do
    %{
      "instance_id" => projection.instance_id,
      "definition_id" => projection.definition_id,
      "correlation_key" => projection.correlation_key,
      "status" => status_string(projection.status),
      "started_at" => DateTime.to_iso8601(projection.started_at)
    }
  end

  # ── GET /instances/:id/history (design §"Router"/history) ──────────────

  defp handle_history(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, id} <- cast_instance_id(raw_id),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, from} <- parse_optional_timestamp(Map.get(query, "from")),
         {:ok, to} <- parse_optional_timestamp(Map.get(query, "to")) do
      params = %{
        event_type: Map.get(query, "event_type"),
        from: from,
        to: to,
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      Instances.history(id, params, opts) |> render_page_result(conn, &history_item_map/1)
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_timestamp} ->
        Response.unprocessable(conn, "from/to must be valid ISO 8601 timestamps")
    end
  end

  defp history_item_map(event) do
    %{
      "event_id" => event.event_id,
      "event_type" => event.event_type,
      "sequence_number" => event.sequence_number,
      "created_at" => DateTime.to_iso8601(event.created_at),
      "payload" => event.payload
    }
  end

  # ── GET /instances/:id/timeline (design §"Router"/timeline) ────────────

  defp handle_timeline(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, id} <- cast_instance_id(raw_id),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{cursor: Map.get(query, "cursor"), page_size: page_size}
      Instances.timeline(id, params, opts) |> render_page_result(conn, &timeline_item_map/1)
    else
      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  defp timeline_item_map(item) do
    %{
      "event_id" => item.event_id,
      "event_type" => item.event_type,
      "sequence_num" => item.sequence_num,
      "instance_id" => item.instance_id,
      "timestamp" => DateTime.to_iso8601(item.timestamp),
      "node_id" => item.node_id,
      "task_id" => item.task_id,
      "metadata" => item.metadata,
      "actor_display_name" => item.actor_display_name,
      "description" => item.description
    }
  end

  # ── Shared page-result rendering (list/history/timeline) ────────────────

  defp render_page_result({:ok, %{items: items, next_cursor: next_cursor}}, conn, item_fn) do
    Response.ok(conn, %{
      "items" => Enum.map(items, item_fn),
      "next_cursor" => next_cursor,
      "count" => length(items)
    })
  end

  defp render_page_result({:error, :not_found}, conn, _item_fn), do: Response.not_found(conn)

  defp render_page_result({:error, :invalid_id}, conn, _item_fn),
    do: Response.unprocessable(conn, "instance_id is not a valid UUID")

  defp render_page_result({:error, :invalid_status}, conn, _item_fn),
    do: Response.unprocessable(conn, "status is not a recognised value")

  defp render_page_result({:error, :invalid_cursor}, conn, _item_fn),
    do: Response.unprocessable(conn, "cursor is not valid for this endpoint")

  defp render_page_result({:error, :wrong_endpoint}, conn, _item_fn),
    do: Response.unprocessable(conn, "cursor is not valid for this endpoint")

  defp render_page_result({:error, :expired}, conn, _item_fn),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp parse_optional_timestamp(nil), do: {:ok, nil}

  defp parse_optional_timestamp(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  # ── GET /instances/:id/pins (design §"Router"/get_pins) ─────────────────

  defp handle_get_pins(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    case cast_instance_id(raw_id) do
      {:ok, id} ->
        render_get_pins(conn, id, PinResolver.reconstruct_effective_pins(id, opts))

      {:error, :invalid_instance_id} ->
        Response.unprocessable(conn, "instance_id is not a valid UUID")
    end
  end

  defp render_get_pins(conn, id, {:ok, pins}) do
    Response.ok(conn, %{"instance_id" => id, "pins" => Enum.map(pins, &pin_map/1)})
  end

  defp render_get_pins(conn, _id, {:error, :instance_not_found}), do: Response.not_found(conn)
  defp render_get_pins(conn, _id, {:error, _internal}), do: Response.internal_error(conn)

  defp pin_map(pin) do
    %{
      "kind" => Atom.to_string(pin.kind),
      "ref" => pin.ref,
      "resolved_id" => pin.resolved_id,
      "version" => pin.version,
      "source" => Atom.to_string(pin.source)
    }
  end

  # Exhaustive over InstanceState.status/0's closed 4-atom union (create_result()
  # only ever produces :active/:completed, a subset -- shared here rather than
  # duplicated). A 5th atom would be a compile-time inexhaustive-case warning,
  # not a silent runtime fallback.
  defp status_string(:active), do: "ACTIVE"
  defp status_string(:completed), do: "COMPLETED"
  defp status_string(:cancelled), do: "CANCELLED"
  defp status_string(:error), do: "ERROR"

  defp validate_schema(schema, body) do
    case Validation.validate(schema, body) do
      {:ok, attrs} -> {:ok, attrs}
      {:errors, field_errors} -> {:errors, field_errors}
    end
  end

  # ── Request parsing ───────────────────────────────────────────────────────

  defp object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  defp cast_instance_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_instance_id}
    end
  end

  defp validate_body(body) do
    case Validation.validate(@rebind_schema, body) do
      {:ok, attrs} -> {:ok, attrs}
      {:errors, field_errors} -> {:errors, field_errors}
    end
  end

  # Per-element shape (kind/ref/version all present, all strings; kind one of
  # the three) has no FieldConstraint vocabulary, so it is checked here and
  # maps to R-Co's 422 INVALID_INPUT.
  defp normalise_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case entry do
        %{"kind" => kind, "ref" => ref, "version" => version}
        when kind in @pin_kinds and is_binary(ref) and is_binary(version) ->
          {:cont, {:ok, [%{kind: kind, ref: ref, version: version} | acc]}}

        _malformed ->
          {:halt, {:error, :invalid_input}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp normalise_entries(_not_a_list), do: {:error, :invalid_input}

  defp scoped_repo_opts(conn) do
    case Context.scoped_repo_opts(conn) do
      {:ok, opts} -> {:ok, opts}
      {:error, _missing_auth_context_or_invalid_tenant_id} -> {:error, :missing_scope_or_actor}
    end
  end

  defp actor_id(conn) do
    case conn.assigns[:auth_context] do
      %{user_id: user_id} when is_binary(user_id) -> {:ok, user_id}
      _other -> {:error, :missing_scope_or_actor}
    end
  end

  # The convention REQ-079/080 must adopt -- see this module's moduledoc.
  defp idempotency_key(conn) do
    case get_req_header(conn, @idempotency_key_header) do
      [value | _rest] when byte_size(value) > 0 -> truncate(value, @max_idempotency_key_bytes)
      _absent_or_empty -> Ecto.UUID.generate()
    end
  end

  # The bound stays in BYTES, because the column is `varchar(255)` and Postgres
  # counts that in characters -- a byte bound can never admit a value the column
  # would reject, while a grapheme bound would let a 255-grapheme multibyte key
  # exceed it.
  #
  # Do NOT "simplify" this back to a bare `binary_part/3`. A header value is
  # arbitrary caller-supplied bytes, so byte 255 can land inside a multibyte
  # UTF-8 sequence and leave an invalid binary. Nothing downstream catches it:
  # Ecto's `:string` cast does not reject invalid UTF-8, and
  # `Letflow.EventStore.Event`'s `validate_length(:idempotency_key, max: 255)`
  # counts graphemes. Postgres is the first thing to object, with
  # `invalid byte sequence for encoding UTF8` -> `Postgrex.Error` -> a bare 500.
  # `trim_to_codepoint_boundary/1` walks back at most 3 bytes to the last whole
  # codepoint, so the result is both valid UTF-8 and still <= max_bytes.
  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate(value, max_bytes) do
    value
    |> binary_part(0, max_bytes)
    |> trim_to_codepoint_boundary()
  end

  defp trim_to_codepoint_boundary(binary) when byte_size(binary) == 0, do: binary

  defp trim_to_codepoint_boundary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_codepoint_boundary()
    end
  end

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  @spec rebind_result_map(PinRebind.rebind_result()) :: map()
  defp rebind_result_map(result) do
    %{
      "instance_id" => result.instance_id,
      "changes" => Enum.map(result.changed, &changed_entry_map/1),
      "rebound_at" => DateTime.to_iso8601(result.rebound_at)
    }
  end

  @spec changed_entry_map(PinRebind.changed_entry()) :: map()
  defp changed_entry_map(changed) do
    %{
      "kind" => Atom.to_string(changed.kind),
      "ref" => changed.ref,
      "prior_version" => changed.prior_version,
      "new_version" => changed.new_version
    }
  end
end
