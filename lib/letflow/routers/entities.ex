defmodule Letflow.Routers.Entities do
  @moduledoc """
  Entity-subsystem sub-router, mounted at `/entities` by
  `Letflow.Plugs.ApiPipeline`. Built to
  `lib/letflow/design/req308-entity-http-surface.md` — §1 is the route table,
  §2 settles one-router-not-two, §5 the security posture, §6 pagination, §7
  the error mapping per delegate.

  REQ-310 creates this module with the **nine** definition and record routes
  below. `POST /entities/query` (§1's tenth row) is REQ-311's, appended to
  this same module later — the module is deliberately shaped so that is an
  append, not a restructure.

  Its permission vocabulary (`:EntitiesDefinitionsRead`,
  `:EntitiesDefinitionsWrite`, `:EntitiesRecordsWrite`, and REQ-311's
  `:EntitiesQuery`) was minted ahead of this router by REQ-309 — every route
  below resolves through a real `Letflow.Api.Authorization.endpoint_policy_key/2`
  clause, so none is on `test/letflow/api/authorization_enforcement_test.exs`'s
  allowlist and none evaluates as `:Unknown`.

  | Handler | Method/path | Delegate | Permission | Response |
  |---|---|---|---|---|
  | create_definition | `POST /entities/definitions` | `Letflow.Entities.Definitions.create_definition/2` | `EntitiesDefinitionsWrite` | 201 / 422 / 409 |
  | activate_definition | `POST /entities/definitions/:name/activate` | `Letflow.Entities.Definitions.activate_definition/4` | `EntitiesDefinitionsWrite` | 200 / 404 / 422 |
  | get_active_definition_by_name | `GET /entities/definitions/active/:name` | `Letflow.Entities.Definitions.get_active_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | get_definition_by_name | `GET /entities/definitions/by-name/:name` | `Letflow.Entities.Definitions.get_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | get_definition | `GET /entities/definitions/:id` | `Letflow.Entities.Definitions.get_definition/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | list_definitions | `GET /entities/definitions` | `Letflow.Entities.Definitions.list_definitions/2` | `EntitiesDefinitionsRead` | 200 / 400 |
  | create_record | `POST /entities/records/:entity_type` | `Letflow.Entities.Records.create_record/2` | `EntitiesRecordsWrite` | 201 / 404 / 422 |
  | update_record | `PUT /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.update_record/2` | `EntitiesRecordsWrite` | 200 / 404 / 409 / 422 |
  | delete_record | `DELETE /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.delete_record/2` | `EntitiesRecordsWrite` | 200 / 404 |

  ## Route ordering — load-bearing, not cosmetic (design §1)

  `Plug.Router` is first-match-wins. `GET /definitions/active/:name` and
  `GET /definitions/by-name/:name` are declared **above**
  `GET /definitions/:id`. Declared below it, the bare `:id` route would match
  first with `id` bound to the literal string `"active"`/`"by-name"`, the
  intended handler never reached, and the request would 404 from a
  non-existent-UUID lookup — with no compile error and no warning anywhere.
  Same hazard class `Letflow.Routers.Definitions`' own moduledoc documents for
  its `/active/:name`/`/search`/`/delta` routes.

  `POST /definitions/:name/activate` is a three-segment path that cannot
  compete with the one-segment `POST /definitions`, and GET/POST/PUT/DELETE
  are independent dispatch tables in `Plug.Router` (so the `/definitions/...`
  GETs never compete with the `/records/...` writes) — but the activate route
  is still declared above `POST /definitions` for readability, matching
  `Letflow.Routers.Definitions`' own precedent.

  ## No route reads a record by id, and none lists records (design §1)

  `Letflow.Entities.Records` is a command-only context module —
  `create_record/2`, `update_record/2`, `delete_record/2` and **no read
  function**. Record reads are exclusively `POST /entities/query`
  (REQ-311); there is deliberately no `GET /entities/records/...` route here
  and no read function was added to `Letflow.Entities.Records` to support one.

  ## INV-1 — the only source of prefix is `conn.assigns.scoped_opts`

  No route below accepts a caller-supplied tenant id, schema name, or slug in
  its path, query string, or body. Every delegate's `prefix` comes from
  `conn.assigns.scoped_opts` (`Letflow.Api.Context.scoped_repo_opts/1`'s
  output, resolved by `Letflow.Plugs.Authorize` from the authenticated
  caller's own token), exactly as `Letflow.Routers.Definitions` and
  `Letflow.Routers.Instances` already do. An actor id comes from
  `conn.assigns.auth_context.user_id`, never from a body or query field.
  This module performs **no `Repo` call of any kind** — every read and write
  happens inside a context module.

  ## INV-5 — not-found and cross-tenant are the same bytes

  `{:error, :not_found}` from the three definition getters and
  `{:error, {:definition_not_found, _}}`/`{:error, {:record_not_found, _}}`
  from `Letflow.Entities.Records` all fold to `Letflow.Api.Response.not_found/1`,
  which takes no detail — so there is no slot through which a cross-tenant
  probe and a genuinely-absent id could differ. They are the same call on the
  same code path: the prefix-scoped lookup makes another tenant's row
  structurally invisible. **No handler adds a cross-tenant existence
  pre-check** to produce a nicer or more specific message — that would
  reintroduce exactly the "exists but forbidden" signal INV-5 forbids.

  ## INV-8 — every error union is mapped exhaustively

  Each delegate's error union is mapped per design §7, each with a catch-all
  `term() -> 500` clause via `Letflow.Api.Response.internal_error/1` (which
  takes no detail, per INV-4). `:invalid_schema_name` and
  `:tenant_not_provisioned` are unreachable through this router (INV-1 makes
  `prefix` server-resolved only) but are mapped for completeness, the same
  "unreachable but mapped" discipline every other router here already uses.
  `:empty_group`, `:duplicate_artifact_in_group` and
  `{:payload_validation_failed, _}` are unreachable for their own separate
  reasons, each stated at its own clause.

  **No handler catches an exception to produce a 4xx.** A caller-error is
  detected by an explicit check and named; an unexpected exception is left
  to propagate, so it surfaces as a logged, detail-free 500 rather than
  being mis-reported to the caller as a validation failure. See
  `build_definition_document/1`'s own comment for the full statement of why
  (REQ-310 rework round 1, REVIEWER blocker 2).
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Api.Validation.FieldError
  alias Letflow.Entities.Definition.Validator.Violation, as: DefinitionViolation
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Registry.ValidationFailure

  # ── Definition write routes ───────────────────────────────────────────
  #
  # "/:name/activate" is a two-segment pattern that cannot collide with the
  # one-segment "/" below regardless of order -- declared above it anyway,
  # matching Letflow.Routers.Definitions' own readability precedent.

  authz_post "/definitions/:name/activate", :EntitiesDefinitionsWrite do
    handle_activate_definition(conn, conn.params["name"])
  end

  authz_post "/definitions", :EntitiesDefinitionsWrite do
    handle_create_definition(conn)
  end

  # ── Definition read routes ────────────────────────────────────────────
  #
  # ⛔ "/definitions/active/:name" and "/definitions/by-name/:name" MUST stay
  # ABOVE "/definitions/:id" -- see this module's moduledoc "Route ordering".
  # Moving either below the bare :id route silently breaks it with no compile
  # error and no warning.

  authz_get "/definitions/active/:name", :EntitiesDefinitionsRead do
    handle_get_active_definition_by_name(conn, conn.params["name"])
  end

  authz_get "/definitions/by-name/:name", :EntitiesDefinitionsRead do
    handle_get_definition_by_name(conn, conn.params["name"])
  end

  authz_get "/definitions/:id", :EntitiesDefinitionsRead do
    handle_get_definition(conn, conn.params["id"])
  end

  authz_get "/definitions", :EntitiesDefinitionsRead do
    handle_list_definitions(conn)
  end

  # ── Record command routes ─────────────────────────────────────────────
  #
  # No GET route under /records exists, by design -- see this module's
  # moduledoc "No route reads a record by id".

  authz_post "/records/:entity_type", :EntitiesRecordsWrite do
    handle_create_record(conn, conn.params["entity_type"])
  end

  authz_put "/records/:entity_type/:record_id", :EntitiesRecordsWrite do
    handle_update_record(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  authz_delete "/records/:entity_type/:record_id", :EntitiesRecordsWrite do
    handle_delete_record(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  match _ do
    Response.not_found(conn)
  end

  # ══ POST /entities/definitions ════════════════════════════════════════
  #
  # Body carries the REQ-225 `Letflow.Entities.Definition.t()` document
  # itself. `created_by` is NEVER read from the body -- it is
  # conn.assigns.auth_context.user_id (INV-1, design §5).

  @create_definition_schema [
    %FieldConstraint{name: "name", required: true, type: :string, reject_empty_string: true},
    %FieldConstraint{
      name: "display_name",
      required: true,
      type: :string,
      reject_empty_string: true
    },
    %FieldConstraint{name: "description", required: false, type: :string},
    %FieldConstraint{name: "fields", required: true, type: :array},
    %FieldConstraint{name: "indexes", required: false, type: :array},
    %FieldConstraint{name: "foreign_keys", required: false, type: :array},
    %FieldConstraint{name: "constraints", required: false, type: :array}
  ]

  defp handle_create_definition(conn) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, _attrs} <- validate_schema(@create_definition_schema, body),
         {:ok, document} <- build_definition_document(body) do
      render_create_definition(
        conn,
        Definitions.create_definition(%{definition: document, created_by: actor_id}, prefix)
      )
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # `Letflow.Entities.Definition.t()` is an ATOM-keyed document whose `type`
  # members are atoms from closed sets -- but a JSON body decodes
  # string-keyed with string `"type"` values. This transliterates the one
  # into the other and does NOTHING ELSE.
  #
  # ## ⛔ This function is TOTAL: it never raises, and it never rejects
  #
  # It returns a document unconditionally. Judging whether that document is
  # a valid entity definition is `Letflow.Entities.Definition.Validator`'s
  # job alone, reached via `Definitions.create_definition/2` ->
  # `{:error, {:validation, violations}}` -> a 422 carrying the real
  # violation list with a per-field `path`.
  #
  # This replaces (REQ-310 rework round 1, REVIEWER blocker 2) an earlier
  # shape that wrapped the whole builder in a bare `rescue` producing one
  # detail-free `{:error, :invalid_definition_document}` -> 422 with NO
  # `errors` key. That was wrong three ways:
  #
  #   1. Its stated premise -- that the Validator would "silently read as
  #      empty" an unconverted value -- is FALSE. `field_shape_violations/1`
  #      tests `Map.get(field, :type) not in @field_types`, a MEMBERSHIP
  #      test that rejects the raw string `"strng"` exactly as it rejects a
  #      wrong atom; `check_required_list_of_maps/3` likewise already emits
  #      "fields entries must all be maps" for a non-map entry. Every
  #      malformation the rescue was catching already had a real, better
  #      violation waiting one layer down.
  #   2. `String.to_existing_atom/1` raising made the caller's error contract
  #      a function of UNRELATED GLOBAL VM STATE: `"type": "strng"` (no such
  #      atom) got the detail-free 422, while `"type": "ok"` (an atom some
  #      other module happens to have loaded) survived conversion and got a
  #      proper field error. Which error a typo produced depended on whether
  #      it collided with an atom loaded elsewhere in the BEAM.
  #   3. The `rescue` had no clause filter, so it would also have caught a
  #      genuine BUG anywhere in this builder and reported it to the caller
  #      as a 422 caller-validation failure, unlogged -- inverting INV-8,
  #      which requires an internal fault to surface as a detail-free 500 AND
  #      be logged. With no raise left to catch, that inversion is gone: an
  #      unexpected exception now propagates to the pipeline's own error
  #      handler as a logged 500, which is the correct INV-8 behaviour.
  #
  # So the conversions below are gated, not rescued: `closed_set_atom/2`
  # checks membership in a compile-time list FIRST and only then calls
  # `String.to_existing_atom/1`, exactly as `Letflow.Routers.Identity`'s
  # `handle_status_update/3` gates its own status conversion behind a
  # `FieldConstraint`'s `allowed_values` before converting. The atom can
  # therefore never be minted and the call can never raise. A value outside
  # the set is passed through UNCHANGED (still a string), where the
  # Validator's membership test rejects it by name and path.
  @spec build_definition_document(map()) :: {:ok, map()}
  defp build_definition_document(body) do
    document =
      %{
        name: Map.get(body, "name"),
        display_name: Map.get(body, "display_name"),
        fields: map_document_list(body, "fields", &definition_field_document/1)
      }
      |> maybe_put_optional(:description, body, "description")
      |> maybe_put_document_list(:indexes, body, "indexes", &index_document/1)
      |> maybe_put_document_list(:foreign_keys, body, "foreign_keys", &fk_document/1)
      |> maybe_put_document_list(:constraints, body, "constraints", &constraint_document/1)

    {:ok, document}
  end

  # The closed sets, duplicated from `Letflow.Entities.Definition`'s
  # `field_type/0` typespec and `constraint_def/0`'s `required(:type) =>
  # :unique` (a typespec cannot be read at runtime) and kept in step with
  # `Letflow.Entities.Definition.Validator`'s own `@field_types`. If they
  # ever drift, the Validator -- not this module -- remains the authority:
  # a type this list omits is passed through as a string and rejected there
  # by name, which is a correct, well-formed error rather than a wrong one.
  @field_type_strings ~w(string integer decimal boolean date datetime enum json localized_text)
  @search_strategy_strings ~w(plain fulltext)
  @constraint_type_strings ~w(unique)

  # `field` is whatever JSON decoded -- possibly not a map at all
  # ("fields": ["not-a-map"]). A non-map entry is returned UNTOUCHED for
  # `check_required_list_of_maps/3` to reject as "fields entries must all be
  # maps"; converting or rejecting it here would replace that precise,
  # path-carrying violation with a vaguer one.
  defp definition_field_document(field) when is_map(field) do
    %{
      name: Map.get(field, "name"),
      type: closed_set_atom(Map.get(field, "type"), @field_type_strings)
    }
    |> maybe_put_optional(:required, field, "required")
    |> maybe_put_optional(:queried, field, "queried")
    |> maybe_put_optional(:enum_values, field, "enum_values")
    |> maybe_put_optional(:decimal_precision, field, "decimal_precision")
    |> maybe_put_optional(:decimal_scale, field, "decimal_scale")
    |> maybe_put_optional(:default, field, "default")
    |> maybe_put_optional(:locales, field, "locales")
    |> maybe_put_search_strategy(field)
  end

  defp definition_field_document(not_a_map), do: not_a_map

  defp maybe_put_search_strategy(document, field) do
    case Map.get(field, "search_strategy") do
      nil -> document
      raw -> Map.put(document, :search_strategy, closed_set_atom(raw, @search_strategy_strings))
    end
  end

  defp index_document(index) when is_map(index) do
    %{name: Map.get(index, "name"), fields: Map.get(index, "fields")}
    |> maybe_put_optional(:unique, index, "unique")
  end

  defp index_document(not_a_map), do: not_a_map

  defp fk_document(fk) when is_map(fk) do
    %{
      name: Map.get(fk, "name"),
      field: Map.get(fk, "field"),
      references_entity: Map.get(fk, "references_entity")
    }
    |> maybe_put_optional(:references_field, fk, "references_field")
  end

  defp fk_document(not_a_map), do: not_a_map

  defp constraint_document(constraint) when is_map(constraint) do
    %{
      name: Map.get(constraint, "name"),
      type: closed_set_atom(Map.get(constraint, "type"), @constraint_type_strings),
      fields: Map.get(constraint, "fields")
    }
  end

  defp constraint_document(not_a_map), do: not_a_map

  # ⛔ The membership test comes FIRST and is what makes
  # `String.to_existing_atom/1` total here: it is only ever reached with a
  # binary drawn from a compile-time literal list, every member of which is
  # an atom already existing in `Letflow.Entities.Definition.Validator`'s own
  # compiled `@field_types`. A non-member -- or a non-binary, e.g.
  # `"type": 7` -- is returned unchanged for the Validator to reject.
  @spec closed_set_atom(term(), [String.t()]) :: atom() | term()
  defp closed_set_atom(raw, allowed) when is_binary(raw) do
    if raw in allowed, do: String.to_existing_atom(raw), else: raw
  end

  defp closed_set_atom(other, _allowed), do: other

  defp maybe_put_optional(document, atom_key, source, string_key) do
    case Map.get(source, string_key) do
      nil -> document
      value -> Map.put(document, atom_key, value)
    end
  end

  # A non-list `fields`/`indexes`/... is passed through unchanged rather than
  # mapped, so the Validator's own "must be a list" violation is what the
  # caller sees. (`@create_definition_schema`'s `type: :array` constraint
  # already catches this first for a top-level key, but this function does
  # not depend on that having run.)
  defp map_document_list(source, string_key, mapper) do
    case Map.get(source, string_key) do
      entries when is_list(entries) -> Enum.map(entries, mapper)
      other -> other
    end
  end

  defp maybe_put_document_list(document, atom_key, source, string_key, mapper) do
    case Map.get(source, string_key) do
      nil -> document
      _present -> Map.put(document, atom_key, map_document_list(source, string_key, mapper))
    end
  end

  # design §7, create_error(): {:validation, violations} -> 422 with the
  # violation list rendered the same way Letflow.Routers.Definitions'
  # render_validation/2 renders a Graph.Violation; {:persistence, changeset}
  # -> 409 (the (tenant_id, name, logical_shape_version) UNIQUE hit is a
  # duplicate); {:repository, _} -> 500; :invalid_schema_name -> 500
  # (unreachable, INV-1).
  defp render_create_definition(conn, {:ok, %EntityDefinition{} = definition}),
    do: Response.created(conn, definition_map(definition))

  defp render_create_definition(conn, {:error, {:validation, violations}}) do
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("entity definition failed validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  defp render_create_definition(conn, {:error, {:persistence, %Ecto.Changeset{}}}),
    do:
      Response.conflict(
        conn,
        "an entity definition with this name and logical shape already exists"
      )

  defp render_create_definition(conn, {:error, {:repository, reason}}) do
    Logger.warning("entity definition create failed in repository pipeline: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  defp render_create_definition(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ══ POST /entities/definitions/:name/activate ═════════════════════════
  #
  # activate_definition/4 is (name, activator_user_id, rationale, prefix) --
  # `activator_user_id` is conn.assigns.auth_context.user_id, NEVER a body
  # field (INV-1). `rationale` IS caller-supplied (it is descriptive text
  # recorded against the activation, carrying no authority).
  #
  # ⛔ `rationale` is `required: true`, and that is not a stylistic choice.
  # The delegate chain REJECTS a blank one: `Letflow.Repository.Activation.
  # activate_group/5` feeds it to `Letflow.Repository.ActivationGroup.
  # changeset/2`, whose `validate_required/2` rejects `nil`, `""` and any
  # whitespace-only string (cast/4 collapses all three to `nil`), with a
  # DB-level `CHECK (rationale <> '')` behind it. So an "optional" rationale
  # is not actually optional anywhere below this line -- declaring it
  # optional here and defaulting to `""` (REQ-310 rework round 1, REVIEWER
  # blocker 1) made an omission fail as `{:group, %Ecto.Changeset{}}`, which
  # this module's render clause collapses into an opaque, field-less 422
  # reading "entity definition could not be activated" and logs as an
  # activation failure rather than a validation one.
  #
  # The alternative -- keeping it optional and substituting a non-blank
  # server-side default -- was rejected: `rationale` is REPO-10's free-text
  # JUSTIFICATION requirement (`Letflow.Repository.Activation`'s moduledoc
  # names it the one mandatory field that table has and REQ-195's
  # `audit_entries` does not). Writing a synthesised justification nobody
  # authored into an append-only compliance trail defeats the field's only
  # purpose. `required: true` instead makes an omission take the SAME RFC
  # 9457 field-error path as every other missing required field in this
  # module, naming `rationale`.
  @activate_definition_schema [
    %FieldConstraint{
      name: "rationale",
      required: true,
      type: :string,
      reject_empty_string: true
    }
  ]

  # ⛔ `reject_empty_string`/`required` are NOT sufficient on their own, and
  # this extra check is not belt-and-braces. `Letflow.Api.Validation`'s
  # `reject_empty_string` tests `value == ""` -- an EXACT comparison -- so
  # `{"rationale": "   "}` passes the schema untouched and then fails three
  # layers down in `ActivationGroup.changeset/2` (whose `cast/4` trims and
  # collapses it to `nil`), landing in this module's
  # `{_tag, %Ecto.Changeset{}}` arm as the very same opaque, field-less 422
  # blocker 1 is about. Found by the blank-rationale test below, which
  # reproduced the defect for `"   "` after `""` was already fixed.
  #
  # Trimming here, against the SAME `String.trim/1` semantics `cast/4`
  # applies, is what makes the router's contract match the delegate's: every
  # string the router accepts, the delegate accepts. The emitted
  # `FieldError` is the same struct `Letflow.Api.Validation` itself returns,
  # so it serialises through the identical `Validation.problem/1` path and a
  # caller cannot tell which of the two produced it.
  defp handle_activate_definition(conn, name) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@activate_definition_schema, body),
         {:ok, rationale} <- non_blank_rationale(Map.fetch!(attrs, "rationale")) do
      render_activate_definition(
        conn,
        Definitions.activate_definition(name, actor_id, rationale, prefix)
      )
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # Returns `{:errors, [FieldError.t()]}` -- deliberately the SAME tagged
  # shape `Letflow.Api.Validation.validate/2` returns, so the `with`'s
  # existing `{:errors, field_errors}` else-arm renders it without a
  # dedicated branch and the caller sees one uniform contract. The
  # `constraint`/`message` pair matches what `validate_field/2` itself emits
  # for a required field that is present-but-blank.
  @spec non_blank_rationale(String.t()) :: {:ok, String.t()} | {:errors, [FieldError.t(), ...]}
  defp non_blank_rationale(rationale) do
    if String.trim(rationale) == "" do
      {:errors,
       [
         %FieldError{
           field: "rationale",
           constraint: "required",
           message: "field is required"
         }
       ]}
    else
      {:ok, rationale}
    end
  end

  # design §7, activate_definition/4: :not_found -> 404 (INV-5 -- a name in
  # another tenant's schema takes this exact path); :empty_group /
  # :duplicate_artifact_in_group -> 422; {:group, _} / {:persistence, _} /
  # {atom(), Ecto.Changeset.t()} -> 422 with ONE generic detail, the real
  # reason logged server-side only (the same collapse
  # Letflow.Routers.Definitions.render_activate/2 already applies to a
  # ServiceScopeValidator violation); :invalid_schema_name -> 500.
  #
  # ⛔ :empty_group and :duplicate_artifact_in_group are UNREACHABLE through
  # this route, and no test drives them (REQ-310 rework round 1, REVIEWER).
  # Both are `Letflow.Repository.Activation.activate_group/5`'s own guards on
  # its `activations` LIST, and `Definitions.activate_definition/4` always
  # builds that list as exactly one element -- a single-element list is never
  # empty and can never contain a duplicate. They are mapped here for
  # completeness only, the same "unreachable but mapped, for defence-in-depth
  # / future-readiness" discipline this module's moduledoc states for
  # :invalid_schema_name and Letflow.Routers.Definitions' own handle_activate
  # states for {:service_scope_violation, _}. If a later requirement lets a
  # caller activate several entity definitions as one group, these become
  # reachable and MUST gain tests then.
  defp render_activate_definition(conn, {:ok, %EntityDefinition{} = definition}),
    do: Response.ok(conn, definition_map(definition))

  defp render_activate_definition(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp render_activate_definition(conn, {:error, :empty_group}),
    do: Response.unprocessable(conn, "activation group is empty")

  defp render_activate_definition(conn, {:error, :duplicate_artifact_in_group}),
    do: Response.unprocessable(conn, "activation group names the same artifact twice")

  defp render_activate_definition(conn, {:error, :invalid_schema_name}),
    do: Response.internal_error(conn)

  defp render_activate_definition(conn, {:error, {_tag, %Ecto.Changeset{}} = reason}) do
    Logger.warning("entity definition activation failed: #{inspect(reason)}")
    Response.unprocessable(conn, "entity definition could not be activated")
  end

  defp render_activate_definition(conn, {:error, _common_error}),
    do: Response.internal_error(conn)

  # ══ GET /entities/definitions/active/:name ════════════════════════════

  defp handle_get_active_definition_by_name(conn, name) do
    render_get_definition(
      conn,
      Definitions.get_active_definition_by_name(name, prefix!(conn))
    )
  end

  # ══ GET /entities/definitions/by-name/:name ═══════════════════════════

  defp handle_get_definition_by_name(conn, name) do
    render_get_definition(conn, Definitions.get_definition_by_name(name, prefix!(conn)))
  end

  # ══ GET /entities/definitions/:id ═════════════════════════════════════
  #
  # `:id` is cast before the delegate call: Definitions.get_definition/2
  # passes it straight to its own repo fetch, which RAISES
  # Ecto.Query.CastError on a non-UUID string rather than returning
  # {:error, :not_found} (unlike Letflow.Definitions.get_by_id/2, which casts
  # internally -- see that module's own OQ-2 note). Casting here
  # collapses malformed-uuid into the SAME zero-detail 404 a
  # well-formed-but-absent id produces -- the stronger INV-5 guarantee, and
  # the reason a mis-ordered "/definitions/active/:name" route (id bound to
  # the literal "active") would 404 rather than 500.

  defp handle_get_definition(conn, raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} -> render_get_definition(conn, Definitions.get_definition(id, prefix!(conn)))
      :error -> Response.not_found(conn)
    end
  end

  # design §7, the three getters: {:error, :not_found} -> 404 (INV-5 -- a
  # cross-tenant id and a nonexistent id are the SAME call producing the SAME
  # zero-detail bytes); {:error, :invalid_schema_name} -> 500 (unreachable).
  defp render_get_definition(conn, {:ok, %EntityDefinition{} = definition}),
    do: Response.ok(conn, definition_map(definition))

  defp render_get_definition(conn, {:error, :not_found}), do: Response.not_found(conn)
  defp render_get_definition(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ══ GET /entities/definitions ═════════════════════════════════════════
  #
  # `cursor`/`page_size` are flat query-string parameters, matching every
  # other paginated GET route in this codebase
  # (Letflow.Routers.Definitions.handle_list/1). Response envelope is
  # {"items": [...], "next_cursor": ...} -- no "count" key (design §6).

  defp handle_list_definitions(conn) do
    prefix = prefix!(conn)
    conn = fetch_query_params(conn)
    query = conn.query_params

    case Pagination.parse_page_size_param(Map.get(query, "page_size")) do
      {:ok, page_size} ->
        filters = %{cursor: Map.get(query, "cursor"), page_size: page_size}
        render_list_definitions(conn, Definitions.list_definitions(filters, prefix))

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")
    end
  end

  # design §7, list_definitions/2: :page_size_too_large/:invalid_cursor/
  # :wrong_endpoint -> 400 (matching render_list_result/2's own identical
  # mapping in Letflow.Routers.Definitions); :expired -> the dedicated
  # cursor-expired problem document every other cursor-consuming route uses;
  # :invalid_schema_name -> 500 (unreachable).
  defp render_list_definitions(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &definition_map/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_list_definitions(conn, {:error, :page_size_too_large}),
    do: Response.bad_request(conn, "page_size out of range")

  defp render_list_definitions(conn, {:error, :invalid_cursor}),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_list_definitions(conn, {:error, :wrong_endpoint}),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  defp render_list_definitions(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp render_list_definitions(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ══ POST /entities/records/:entity_type ═══════════════════════════════
  #
  # create_record/2's create_attrs() is
  # %{entity_type, field_values, actor_id, idempotency_key} -- `entity_type`
  # comes from the PATH segment (never a body field), `actor_id` from
  # conn.assigns.auth_context.user_id (INV-1), `idempotency_key` from the
  # body when the caller supplies one (it is the caller's own replay token,
  # carrying no authority) and otherwise freshly minted so the delegate's
  # required key is always present.

  @record_write_schema [
    %FieldConstraint{name: "field_values", required: true, type: :object},
    %FieldConstraint{
      name: "idempotency_key",
      required: false,
      type: :string,
      reject_empty_string: true
    }
  ]

  defp handle_create_record(conn, entity_type) do
    prefix = prefix!(conn)

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@record_write_schema, body) do
      command_attrs = %{
        entity_type: entity_type,
        field_values: Map.fetch!(attrs, "field_values"),
        actor_id: conn.assigns.auth_context.user_id,
        idempotency_key: idempotency_key(attrs)
      }

      render_record_command(conn, Records.create_record(command_attrs, prefix), :created)
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # ══ PUT /entities/records/:entity_type/:record_id ═════════════════════
  #
  # Full replacement of `field_values` (update_record/2's own whole-document
  # semantics).

  defp handle_update_record(conn, entity_type, raw_record_id) do
    prefix = prefix!(conn)

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@record_write_schema, body) do
      command_attrs = %{
        entity_type: entity_type,
        record_id: record_id,
        field_values: Map.fetch!(attrs, "field_values"),
        actor_id: conn.assigns.auth_context.user_id,
        idempotency_key: idempotency_key(attrs)
      }

      render_record_command(conn, Records.update_record(command_attrs, prefix), :ok)
    else
      # INV-5: a malformed record id takes the same zero-detail 404 a
      # well-formed-but-absent (or cross-tenant) one takes.
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # ══ DELETE /entities/records/:entity_type/:record_id ══════════════════
  #
  # Bodyless. delete_record/2 treats an already-deleted record as a no-op
  # success (its own documented domain-level idempotency), so no 409 branch
  # is reachable through this route -- {:record_already_deleted, _} is still
  # mapped below, on the shared renderer, for completeness.

  defp handle_delete_record(conn, entity_type, raw_record_id) do
    case cast_record_id(raw_record_id) do
      {:ok, record_id} ->
        command_attrs = %{
          entity_type: entity_type,
          record_id: record_id,
          actor_id: conn.assigns.auth_context.user_id,
          idempotency_key: Ecto.UUID.generate()
        }

        render_record_command(conn, Records.delete_record(command_attrs, prefix!(conn)), :ok)

      {:error, :invalid_record_id} ->
        Response.not_found(conn)
    end
  end

  # Casting here (rather than letting Latest.get/3 receive a non-UUID string)
  # keeps a malformed id on the same zero-detail 404 path as an absent one.
  defp cast_record_id(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, record_id} -> {:ok, record_id}
      :error -> {:error, :invalid_record_id}
    end
  end

  defp idempotency_key(attrs) do
    case Map.get(attrs, "idempotency_key") do
      key when is_binary(key) -> key
      nil -> Ecto.UUID.generate()
    end
  end

  # design §7, Records.command_error(), mapped exhaustively:
  #   {:definition_not_found, _}     -> 404  (INV-5)
  #   {:record_not_found, _}         -> 404  (INV-5)
  #   {:record_payload_invalid, v}   -> 422 with the violation list
  #   {:payload_validation_failed,_} -> 422
  #   {:record_already_deleted, _}   -> 409
  #   :tenant_not_provisioned        -> 500  (unreachable, INV-1)
  #   :invalid_schema_name           -> 500  (unreachable, INV-1)
  #   any other term()               -> 500  (INV-8 catch-all, no detail)
  defp render_record_command(conn, {:ok, %{record: %Latest{} = record}}, :created),
    do: Response.created(conn, record_map(record))

  defp render_record_command(conn, {:ok, %{record: %Latest{} = record}}, :ok),
    do: Response.ok(conn, record_map(record))

  defp render_record_command(conn, {:error, {:definition_not_found, _entity_type}}, _status),
    do: Response.not_found(conn)

  defp render_record_command(conn, {:error, {:record_not_found, _record_id}}, _status),
    do: Response.not_found(conn)

  defp render_record_command(conn, {:error, {:record_payload_invalid, violations}}, _status) do
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("entity record payload failed validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  # ⛔ UNREACHABLE through these three routes, and no test drives it
  # (REQ-310 rework round 1, REVIEWER). This is REQ-024's OUTER envelope
  # check firing inside `EventStore.append_multi/3` -- it reports that the
  # EVENT PAYLOAD this router's own delegate constructed violates the
  # registered event-type schema, not that the caller's `field_values` are
  # wrong (that is `{:record_payload_invalid, _}` above, which IS reachable
  # and IS tested). `Letflow.Entities.Records` always builds an envelope
  # satisfying its own registered schema, so reaching this clause would mean
  # an internal construction bug or a schema tightening, not caller input --
  # exactly the framing `req228`'s own design table gives it. Mapped for
  # completeness, per this module's "unreachable but mapped" discipline; it
  # stays a 422 rather than a 500 because design §7's table assigns it one.
  defp render_record_command(conn, {:error, {:payload_validation_failed, _errors}}, _status),
    do: Response.unprocessable(conn, "entity record payload failed validation")

  defp render_record_command(conn, {:error, {:record_already_deleted, _record_id}}, _status),
    do: Response.conflict(conn, "entity record is already deleted")

  defp render_record_command(conn, {:error, reason}, _status)
       when reason in [:tenant_not_provisioned, :invalid_schema_name],
       do: Response.internal_error(conn)

  defp render_record_command(conn, {:error, reason}, _status) do
    Logger.warning("entity record command failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ Response allowlists (INV-2) ═══════════════════════════════════════

  @spec definition_map(EntityDefinition.t()) :: map()
  defp definition_map(%EntityDefinition{} = definition) do
    %{
      "id" => definition.id,
      "name" => definition.name,
      "display_name" => definition.display_name,
      "definition" => definition.definition_json,
      "content_hash" => Base.encode16(definition.content_hash, case: :lower),
      "logical_shape_version" => Base.encode16(definition.logical_shape_version, case: :lower),
      "artifact_version_id" => definition.artifact_version_id,
      "status" => Atom.to_string(definition.status),
      "inserted_at" => DateTime.to_iso8601(definition.inserted_at)
    }
  end

  # `tenant_id` is deliberately NOT in this allowlist -- a caller is already
  # scoped to exactly one tenant and echoing the id back adds nothing but a
  # tenant identifier on the wire.
  @spec record_map(Latest.t()) :: map()
  defp record_map(%Latest{} = record) do
    %{
      "record_id" => record.record_id,
      "entity_type" => record.entity_type,
      "field_values" => record.field_values,
      "deleted" => record.deleted,
      "entity_def_version" => Base.encode16(record.entity_def_version, case: :lower),
      "last_event_global_seq" => record.last_event_global_seq
    }
  end

  # ══ Helpers ═══════════════════════════════════════════════════════════

  # INV-1: the ONE source of prefix on every route in this module. Never a
  # path, query or body value.
  #
  # Every delegate in `Letflow.Entities.*` takes a BARE `prefix ::
  # String.t()` positional argument (see each one's own @spec), not the
  # `[prefix: schema]` keyword list `Letflow.Routers.Definitions`/
  # `Letflow.Routers.Instances` hand straight to their own
  # `Letflow.Definitions.*`/`Letflow.Repository.*` delegates as `opts`. So
  # this router unwraps `conn.assigns.scoped_opts` here rather than passing
  # it through -- the difference is in the delegates' signatures, not in
  # where the value comes from, which is identical to every other router.
  # `Keyword.fetch!/2` deliberately raises rather than defaulting: reaching a
  # handler without `:scoped_opts` assigned is structurally impossible
  # (`Letflow.Plugs.Authorize` assigns it before `:dispatch` or halts), and a
  # silent default would be a tenant-scoping bug, not a recoverable one.
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

  # The two violation shapes this module can receive have DISJOINT fields, so
  # each gets its own clause rather than one Map.get-based reader that would
  # silently emit nils for whichever shape it was not written against:
  #
  #   * Letflow.Entities.Definition.Validator.Violation -- rule/path/message
  #     (from create_definition/2's {:validation, violations});
  #   * Letflow.EventStore.Registry.ValidationFailure -- field_path/
  #     constraint/actual (from Records' {:record_payload_invalid, violations}).
  #
  # Both become plain string-keyed maps: Letflow.Api.Error.serialise/1's
  # `errors: [_ | _]` clause hands the list straight to Jason.encode!/1.
  # `actual` (the caller's own rejected value) is deliberately NOT echoed --
  # it adds nothing the caller does not already have and keeps this body free
  # of arbitrary tenant data.
  @spec violation_map(DefinitionViolation.t() | ValidationFailure.t()) :: map()
  defp violation_map(%DefinitionViolation{rule: rule, path: path, message: message}) do
    %{
      "code" => Atom.to_string(rule),
      "path" => Enum.map(path, &to_string/1),
      "message" => message
    }
  end

  defp violation_map(%ValidationFailure{field_path: field_path, constraint: constraint}) do
    %{
      "code" => constraint,
      "path" => field_path,
      "message" => "#{field_path} violates #{constraint}"
    }
  end
end
