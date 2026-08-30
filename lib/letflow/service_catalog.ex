defmodule Letflow.ServiceCatalog do
  @moduledoc """
  Context module for the `service_catalog` table's core lifecycle:
  `register/1`, `get_for_tenant/2`, `list_for_tenant/2`, `update_scope/2`,
  `delete/1`. See `lib/letflow/design/req191-service-catalog-core.md` for the
  full design this module implements. Plain Ecto context module, no
  process — same shape as `Letflow.Dlq`/`Letflow.Identity`.

  Ports R-Co `migrations/049_repository_service_catalog.sql` plus
  `GBL-117_svc01_service_catalog_scope.sql` (SVC-01), and supplies the real
  implementation seam three already-shipped modules (SVC-03's
  `Letflow.Definitions.ServiceScopeValidator`, PIN-01's `PinResolver`, and
  `Letflow.Definitions.SolutionPack`'s `service_catalog_entries` handling)
  already anticipate but cannot yet use.

  **Scope boundary, restated from the design (§0):** schema/migration, this
  context module's five functions, the two referential guards, a `Lookup`
  implementation for `ServiceScopeValidator`, and the explicit resolution of
  `SolutionPack`'s `service_catalog_entries` hard-fail. No route, no
  controller — that is REQ-192. No `service_scope_validator.ex` change — its
  algorithm and injectable-`Lookup` shape are frozen; this module supplies an
  implementation of that shape only. No `pin_resolver.ex` change.

  ## GLOBAL table — divergence from decision 0003 Decision B, flagged for
  ## REVIEWER sign-off

  `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B makes
  schema-per-tenant (Ecto `:prefix`-scoped tables, `tenant_id` retained
  intra-schema) the general rule for business tables. `service_catalog`
  deliberately does **not** follow that rule — it is a single table in the
  default/public schema, with no `:prefix` option on its migration and no
  registration in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`.

  **R-Co-grounded reason, structural not incidental:** a `scope = :global`
  service-catalog entry is by definition referenceable by every tenant, and
  `service_id` is unique across all tenants regardless of scope (R-Co's
  SVC-01 rule, `GBL-117_svc01_service_catalog_scope.sql`). Neither property
  can be expressed by a per-tenant-schema copy: a per-tenant copy could not
  enforce global `service_id` uniqueness across schemas without a
  cross-schema mechanism Decision B doesn't provide, and a `scope = :global`
  row would need to exist identically in every tenant's schema
  simultaneously, which is not what schema-per-tenant means. This is exactly
  the same shape as REQ-041's `solution_pack_installs`/
  `solution_pack_artefact_bases`/`pack_update_resolutions`
  (`priv/repo/migrations/20260817083801_create_solution_pack_installs.exs`'s
  own moduledoc: "install records are cross-tenant infrastructure") — this
  module follows that already-accepted precedent rather than inventing a new
  one.

  No `tenant_id` column exists on this table at all — Decision B's "retain
  `tenant_id` intra-schema" clause only applies to tables that live inside a
  tenant's own schema; this table doesn't, and `owner_tenant_id` already
  carries the one tenant association this table needs.

  **REVIEWER sign-off: AGREE, 2026-08-30 (WF02-REQ191-20260830 Step 2d).**
  Full reasoning recorded in
  `lib/letflow/design/req191-service-catalog-core.md` §0 — this is a real
  architectural decision (a global table is a different security/scaling
  surface than schema-per-tenant), signed off on independent structural
  grounds, not on the `solution_pack_installs` precedent alone.

  ## No `opts[:prefix]` on any function

  Unlike every other S6 context module, this one's backing table is global,
  so there is no tenant schema to scope queries into. Every function instead
  takes an explicit `tenant_id :: Ecto.UUID.t()` argument where visibility
  needs to be resolved (`get_for_tenant/2`, `list_for_tenant/2`), or a
  registered-tenant lookup where existence needs confirming (`register/1`).

  ## Function arity — a deliberate deviation from the design's provisional
  ## `register/2`/`delete/2` naming (design §7 OQ-1)

  The design doc's own §7 OQ-1 leaves `register/2`'s exact arity open,
  noting only that a documented reason may justify diverging from the
  requirement text's provisional "register/2"/"delete/2" naming. This module
  implements `register/1` and `delete/1`: both functions' second "argument"
  in the design's own prose was either an injectable tenant-existence-check
  function (resolved here instead via a direct `Letflow.Identity.Tenant`
  query, per the design's own permitted alternative) or an `opts` slot this
  module has nothing to put in it (no `:prefix` — see above). Adding an
  unused `opts \\\\ []` parameter to either function purely to preserve a
  surface-level arity match would be exactly the kind of unneeded
  abstraction `CLAUDE.md`'s "match effort to the active stage" rule
  forbids. `get_for_tenant/2`, `list_for_tenant/2`, and `update_scope/2` keep
  their full two real-argument arity because both arguments in each case are
  genuine business inputs, not a stand-in for a slot this module doesn't use.

  ## SVC-04 permissions (REQ-069) — not wired here, and not contradicted

  `:ServicesRead`, `:AdminServicesRead`, `:AdminServicesManage`
  (`Letflow.Api.Authorization`) are the already-shipped permission names for
  this catalog's future HTTP surface. This requirement has no route layer,
  so no permission is enforced here — REQ-192 wires the route/permission
  pairing. This moduledoc names them only so a future reader of this module
  doesn't independently invent a different name for the same concept.
  """

  import Ecto.Query

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.ServiceScopeValidator.Lookup
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.TenantProvisioning
  alias Letflow.Api.Pagination

  @list_cursor_prefix "SC:"
  @list_all_cursor_prefix "SCA:"

  # ===========================================================================
  # register/1 (design §3.1)
  # ===========================================================================

  @typedoc "Keyed by `Letflow.ServiceCatalog.Entry`'s own field names, minus `created_at`/`updated_at`."
  @type register_attrs :: %{
          required(:service_id) => String.t(),
          required(:endpoint_url) => String.t(),
          optional(:request_schema) => String.t() | nil,
          optional(:response_schema) => String.t() | nil,
          optional(:required_auth) => atom() | String.t(),
          required(:timeout_ms) => integer(),
          optional(:retry_policy) => String.t() | nil,
          optional(:scope) => atom() | String.t(),
          optional(:owner_tenant_id) => Ecto.UUID.t() | nil
        }

  @doc """
  Inserts a new `service_catalog` row.

  When `attrs.scope` is `:tenant` (or `"tenant"`) and `attrs.owner_tenant_id`
  is a syntactically-valid UUID, confirms the named tenant exists via a
  direct `Letflow.Identity.Tenant` lookup **before** any insert is
  attempted — a miss returns `{:error, :tenant_not_found}` with no row
  created (design §3.1 step 2). When `attrs.scope` is `:global`, no tenant
  lookup is performed.

  `created_at`/`updated_at` are stamped here (`DateTime.utc_now/0`, truncated
  to microsecond), never caller-settable.

  `service_id` is globally unique by virtue of being the table's primary
  key — a conflicting insert surfaces as `{:error, :duplicate_service_id}`,
  a typed atom distinguishable from an ordinary validation failure
  (mirrors `Letflow.Dlq`/`Letflow.Definitions.SolutionPack`'s own
  typed-error-atom convention), never a silent overwrite.
  """
  @spec register(register_attrs()) ::
          {:ok, Entry.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :tenant_not_found}
          | {:error, :duplicate_service_id}
  def register(attrs) when is_map(attrs) do
    with :ok <- check_tenant_exists(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      # `created_at`/`updated_at` are set on the base struct, not cast from
      # `attrs` -- `Entry.insert_changeset/2` deliberately never casts either
      # field (its own moduledoc), so they must be present on the struct
      # `cast/3` starts from rather than passed through `attrs`.
      %Entry{created_at: now, updated_at: now}
      |> Entry.insert_changeset(attrs)
      |> Repo.insert()
      |> map_insert_result()
    end
  end

  defp check_tenant_exists(%{scope: scope} = attrs) when scope in [:tenant, "tenant"] do
    case Map.get(attrs, :owner_tenant_id) do
      owner_tenant_id when is_binary(owner_tenant_id) ->
        case Ecto.UUID.cast(owner_tenant_id) do
          {:ok, uuid} -> tenant_exists?(uuid)
          # Not a well-formed UUID at all -- let the changeset/DB surface an
          # ordinary validation error rather than this function guessing.
          :error -> :ok
        end

      _missing_or_nil ->
        :ok
    end
  end

  defp check_tenant_exists(_attrs), do: :ok

  defp tenant_exists?(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      nil -> {:error, :tenant_not_found}
      %Tenant{} -> :ok
    end
  end

  defp map_insert_result({:ok, entry}), do: {:ok, entry}

  defp map_insert_result({:error, %Ecto.Changeset{} = changeset}) do
    if duplicate_service_id_error?(changeset) do
      {:error, :duplicate_service_id}
    else
      {:error, changeset}
    end
  end

  defp duplicate_service_id_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:service_id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  # ===========================================================================
  # get_for_tenant/2 (design §3.2)
  # ===========================================================================

  @doc """
  Fetches a single `service_catalog` row and applies SVC-01's three-way
  visibility rule, in a single query plus a pure in-memory check (never a
  second, differently-shaped query depending on the outcome — this is what
  makes the "genuinely missing" and "real but invisible" cases structurally
  indistinguishable, not merely coincidentally same-shaped):

    * no row at all -> `{:error, :not_found}`
    * `scope: :global` -> `{:ok, entry}`, for any `tenant_id`
    * `scope: :tenant, owner_tenant_id: tenant_id` -> `{:ok, entry}`
    * `scope: :tenant` owned by a *different* tenant -> `{:error, :not_found}`
      — the identical atom the genuinely-missing case returns, never a
      `:forbidden`/`:unauthorized` variant (SVC-01's non-disclosure rule).
  """
  @spec get_for_tenant(service_id :: String.t(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, Entry.t()} | {:error, :not_found}
  def get_for_tenant(service_id, tenant_id) when is_binary(service_id) and is_binary(tenant_id) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_found}

      %Entry{scope: :global} = entry ->
        {:ok, entry}

      %Entry{scope: :tenant, owner_tenant_id: owner_tenant_id} = entry
      when owner_tenant_id == tenant_id ->
        {:ok, entry}

      %Entry{scope: :tenant} ->
        {:error, :not_found}
    end
  end

  # ===========================================================================
  # list_for_tenant/2 (design §3.3)
  # ===========================================================================

  @typedoc "Mirrors `Letflow.Dlq.list/2`'s own `list_params()` cursor shape."
  @type list_params :: %{
          optional(:cursor) => String.t() | nil,
          page_size: pos_integer()
        }

  @doc """
  Cursor-paginated listing of every `service_catalog` row visible to
  `tenant_id` — every `scope: :global` row plus every `scope: :tenant` row
  this tenant owns. Ordered `(created_at DESC, service_id DESC)`, using
  `service_id` (the primary key) as the keyset tiebreaker since this table
  has no other unique column to break ties on. Reuses
  `Letflow.Api.Pagination`'s cursor-encode/decode module and
  `Letflow.Dlq.list/2`'s own `page_size + 1`-fetch/drop-the-extra-row idiom
  exactly — no new cursor format invented.
  """
  @spec list_for_tenant(list_params(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, %{items: [Entry.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  def list_for_tenant(params, tenant_id) when is_map(params) and is_binary(tenant_id) do
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      query =
        Entry
        |> where([e], e.scope == :global or e.owner_tenant_id == ^tenant_id)
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([e], desc: e.created_at, desc: e.service_id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query)
      {page, next_cursor} = split_list_page(rows, page_size, @list_cursor_prefix)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {created_at_us, service_id}) do
    ts = DateTime.from_unix!(created_at_us, :microsecond)
    from(e in query, where: {e.created_at, e.service_id} < {^ts, ^service_id})
  end

  @spec decode_list_cursor(String.t() | nil) ::
          {:ok, {non_neg_integer(), String.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @list_cursor_prefix, byte_size(@list_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_seek(cursor, @list_cursor_prefix)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek(%Pagination.Cursor{inner: inner}, prefix) do
    prefix_len = byte_size(prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [ts_str, service_id] = String.split(rest, ":", parts: 2)
    {String.to_integer(ts_str), service_id}
  end

  # `prefix` is threaded through here (rather than each caller building its
  # own cursor after the fact) so `list_for_tenant/2` and `list_all/1` can
  # genuinely share this function's body verbatim while still minting a
  # cursor tagged with the calling function's own endpoint prefix (INV-9) --
  # a shared helper that silently hardcoded one prefix would mis-tag the
  # other endpoint's cursors.
  defp split_list_page(rows, page_size, prefix) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page), prefix)}
  end

  defp split_list_page(rows, _page_size, _prefix), do: {rows, nil}

  defp build_list_next_cursor(%Entry{service_id: service_id, created_at: created_at}, prefix) do
    created_at_us = DateTime.to_unix(created_at, :microsecond)

    prefix
    |> Pagination.build_raw_cursor(created_at_us, service_id)
    |> Pagination.encode_cursor()
  end

  # ===========================================================================
  # list_all/1 (design req192-service-catalog-routes.md §5, rework iteration 2)
  # ===========================================================================

  @doc """
  Cursor-paginated listing of **every** `service_catalog` row, with **no**
  tenant or scope filtering whatsoever — unlike `list_for_tenant/2`, this
  function performs no visibility check at all. It exists solely to back
  `Letflow.Routers.AdminServices`'s `GET /admin/services` handler, a
  `PLATFORM_ADMIN`-only route (`Letflow.Api.Authorization`'s
  `:AdminServicesRead`/`:UsersGroupsRolesManage` mapping); this module has
  never enforced authorization (per this moduledoc's "SVC-04 permissions"
  section) and does not start here — **the caller is entirely responsible
  for ensuring only an authorized admin path ever calls this function.**

  Added as a deliberate, REVIEWER-flagged scope expansion beyond REQ-192's
  original "no context-module change" note — see
  `lib/letflow/design/req192-service-catalog-routes.md` §5 for the full
  reasoning (a hard conflict between that note and `INV-RT-1`, REQ-078's
  "no `Repo.` call under `lib/letflow/routers/`" invariant).

  Otherwise identical in shape to `list_for_tenant/2`: same `list_params()`
  input, same result shape, same ordering
  (`(created_at DESC, service_id DESC)`), same `page_size + 1`-fetch/
  drop-the-extra-row idiom, and reuses `filter_by_list_cursor/2`/
  `split_list_page/2` verbatim (both are already tenant-agnostic). Uses its
  own cursor prefix, `"SCA:"`, distinct from `list_for_tenant/2`'s `"SC:"` —
  a cursor minted by one is rejected with `{:error, :wrong_endpoint}` if
  replayed against the other (INV-9 cross-endpoint cursor isolation,
  `Letflow.Api.Pagination.decode_cursor/3`'s `check_prefix/2`).

  `list_for_tenant/2` itself is entirely unchanged by this addition — same
  name, arity, body, and `where` clause.
  """
  @spec list_all(list_params()) ::
          {:ok, %{items: [Entry.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  def list_all(params) when is_map(params) do
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_list_all_cursor(Map.get(params, :cursor)) do
      query =
        Entry
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([e], desc: e.created_at, desc: e.service_id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query)
      {page, next_cursor} = split_list_page(rows, page_size, @list_all_cursor_prefix)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  @spec decode_list_all_cursor(String.t() | nil) ::
          {:ok, {non_neg_integer(), String.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_all_cursor(nil), do: {:ok, nil}

  defp decode_list_all_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @list_all_cursor_prefix,
           byte_size(@list_all_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_seek(cursor, @list_all_cursor_prefix)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # ===========================================================================
  # update_scope/2 (design §3.4)
  # ===========================================================================

  @typedoc "Cast by `Entry.update_scope_changeset/2`."
  @type update_scope_attrs :: %{
          required(:scope) => :global | :tenant,
          optional(:owner_tenant_id) => Ecto.UUID.t() | nil
        }

  @typedoc "One tenant's conflicting ACTIVE-definition references, per design §4 step 3."
  @type reference_conflict :: %{tenant_id: Ecto.UUID.t(), definition_ids: [String.t()]}

  @doc """
  Updates a `service_catalog` row's `scope`/`owner_tenant_id`.

  **Narrowing** (`:global -> :tenant`) runs the referential guard (§4 below)
  against every tenant *other than* `new_attrs.owner_tenant_id` — the tenant
  the service is being assigned to is allowed to already reference it; only
  *other* tenants' references block the narrow. A non-empty guard result is
  `{:error, {:referenced_by_active_definitions, conflicts}}`, naming the
  conflicting tenant ids, and no write happens.

  **Widening** (`:tenant -> :global`) always proceeds, skipping the guard
  entirely, per the acceptance criterion's explicit "widening... is always
  allowed". A global-to-global or tenant-to-tenant no-op scope change also
  skips the guard (neither narrows visibility).
  """
  @spec update_scope(service_id :: String.t(), update_scope_attrs()) ::
          {:ok, Entry.t()}
          | {:error, :not_found}
          | {:error, {:referenced_by_active_definitions, [reference_conflict()]}}
          | {:error, Ecto.Changeset.t()}
  def update_scope(service_id, new_attrs) when is_binary(service_id) and is_map(new_attrs) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_found}

      %Entry{} = entry ->
        if narrowing?(entry, new_attrs) do
          case referencing_active_definitions(service_id, Map.get(new_attrs, :owner_tenant_id)) do
            [] -> apply_update_scope(entry, new_attrs)
            conflicts -> {:error, {:referenced_by_active_definitions, conflicts}}
          end
        else
          apply_update_scope(entry, new_attrs)
        end
    end
  end

  defp narrowing?(%Entry{scope: :global}, %{scope: scope}) when scope in [:tenant, "tenant"],
    do: true

  defp narrowing?(_entry, _new_attrs), do: false

  defp apply_update_scope(entry, new_attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entry
    |> Entry.update_scope_changeset(new_attrs)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Repo.update()
  end

  # ===========================================================================
  # delete/1 (design §3.5)
  # ===========================================================================

  @doc """
  Deletes a `service_catalog` row, refused when any tenant's ACTIVE
  `process_definitions` graph still references it (§4 below) — delete has no
  "assigned tenant" exemption the way `update_scope/2`'s narrow does; every
  tenant is checked. The error names every referencing definition id.
  """
  @spec delete(service_id :: String.t()) ::
          :ok
          | {:error, :not_found}
          | {:error, {:referenced_by_active_definitions, [String.t()]}}
  def delete(service_id) when is_binary(service_id) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_found}

      %Entry{} = entry ->
        case referencing_active_definitions(service_id, nil) do
          [] ->
            delete_entry(entry)

          conflicts ->
            definition_ids = Enum.flat_map(conflicts, & &1.definition_ids)
            {:error, {:referenced_by_active_definitions, definition_ids}}
        end
    end
  end

  # `entry` was fetched at the top of `delete/1`, but `referencing_active_definitions/2`
  # runs a sequential per-tenant-schema query loop in between -- a real window in which a
  # concurrent caller can delete the same row first. `Entry` carries no optimistic-lock
  # field, so `Repo.delete/1` matches on primary key alone: if the row is already gone,
  # it raises `Ecto.StaleEntryError` rather than returning `{:error, changeset}`. Treat
  # that race as a benign not-found (consistent with `get_for_tenant/2`'s own not-found
  # handling) instead of letting it crash the caller.
  defp delete_entry(entry) do
    case Repo.delete(entry) do
      {:ok, _deleted} -> :ok
      {:error, _changeset} -> {:error, :not_found}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  # ===========================================================================
  # §4 — the referential guard, structural (not `LIKE`-on-serialized-JSON)
  # ===========================================================================
  #
  # R-Co's `bpm_active_defs_for_service` runs
  # `WHERE graph_json LIKE '%' || service_id || '%'` against the serialized
  # definition-graph text -- over-matching any occurrence of the service_id
  # substring anywhere in the JSON, even inside an unrelated string value.
  # This guard instead walks the graph's actual node structure: it matches
  # only a SERVICE_TASK node's own "service_id" attribute, the same
  # (node_type, attribute_key) pairing Letflow.Definitions.Graph's own
  # node_type filtering already establishes (graph.ex's
  # `Enum.filter(&(&1.node_type == :SERVICE_TASK))` idiom), reused here at
  # the SQL layer via a `jsonb_array_elements`/`EXISTS` correlated subquery
  # instead of after full deserialization, since this must run cross-schema.
  #
  # `process_definitions` is a per-tenant-schema table (Decision B) -- a
  # service's ACTIVE referencing definitions can live in *any* tenant's own
  # schema, so this guard iterates every provisioned tenant schema
  # (`Letflow.TenantProvisioning.list_registrations/0`) rather than running
  # as a single same-schema `Ecto.Query`. Stated cost, not solved here
  # (design §7 OQ-2): no caching/indexing/async mechanism is proposed.

  @spec referencing_active_definitions(
          service_id :: String.t(),
          exclude_tenant_id :: Ecto.UUID.t() | nil
        ) :: [reference_conflict()]
  defp referencing_active_definitions(service_id, exclude_tenant_id) do
    TenantProvisioning.list_registrations()
    |> Enum.reject(fn registration -> registration.tenant_id == exclude_tenant_id end)
    |> Enum.map(fn registration ->
      %{
        tenant_id: registration.tenant_id,
        definition_ids: query_referencing_definitions(service_id, registration.schema_name)
      }
    end)
    |> Enum.reject(fn %{definition_ids: ids} -> ids == [] end)
  end

  @service_task_reference_fragment """
  EXISTS (
    SELECT 1 FROM jsonb_array_elements(?->'nodes') AS node
    WHERE node->>'node_type' = 'SERVICE_TASK'
      AND node->'attributes'->>'service_id' = ?
  )
  """

  defp query_referencing_definitions(service_id, schema_name) do
    query =
      from(p in ProcessDefinition,
        where: p.status == :active,
        where: fragment(@service_task_reference_fragment, p.graph, ^service_id),
        select: p.id
      )

    Repo.all(query, prefix: schema_name)
  end

  # ===========================================================================
  # §5 — `Lookup` implementation for `ServiceScopeValidator`
  # ===========================================================================

  @doc """
  Builds a `Letflow.Definitions.ServiceScopeValidator.Lookup.t()` backed by
  this catalog — without any edit to `service_scope_validator.ex`.

  `service_lookup` is a direct `service_id -> service_lookup_result()`
  field mapping (`Repo.get(Entry, service_id)`, no `tenant_id` filtering):
  `ServiceScopeValidator`'s own branch table already performs the
  global/tenant-match/mismatch comparison against the activating
  `tenant_id` on the caller side (`validate/3`'s own second argument) — this
  `Lookup` only needs to report what is registered, not decide visibility a
  second time (design §5). `tenant_id` is still accepted here (this function
  is constructed per-activation, `scope_validator_lookup(tenant_id)`,
  mirroring `ServiceScopeValidator.build/1`'s own per-activation closure
  pattern) even though the current implementation's `service_lookup` body
  does not read it, for exactly the reason just stated.

  `plugin_lookup` is a stub that always returns `{:error, :not_registered}`
  — `PluginRegistry` is stage S3, out of scope for REQ-191
  (`service_scope_validator.ex`'s own moduledoc names this gap; INV-SSV-5
  already makes "not registered" a pass on the plugin side, so this never
  blocks activation).
  """
  @spec scope_validator_lookup(tenant_id :: Ecto.UUID.t()) :: Lookup.t()
  def scope_validator_lookup(_tenant_id) do
    %Lookup{
      service_lookup: &lookup_service/1,
      plugin_lookup: fn _plugin_handler, _tenant_id -> {:error, :not_registered} end
    }
  end

  defp lookup_service(service_id) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_registered}

      %Entry{scope: scope, owner_tenant_id: owner_tenant_id} ->
        {:ok, %{scope: scope, owner_tenant_id: owner_tenant_id}}
    end
  end
end
