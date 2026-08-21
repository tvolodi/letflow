defmodule Letflow.Identity do
  @moduledoc """
  Context module for the identity domain. `provision_oidc_user/4` (below) ports
  the JIT (just-in-time) user-provisioning orchestration from
  `src/oidc/jit_provisioning.zig` together with the actual upsert from
  `src/identity/registry.zig`'s `createOrGetJitOidcUser` (lines ~843-912),
  operating on REQ-015's `users` schema (`Letflow.Identity.User`), now relocated
  per-tenant-schema per REQ-063 (`opts[:prefix]` selects the target schema — see
  `provision_oidc_user/4`'s own @doc).

  `resolve_tenant_by_realm/1`, `resolve_realm_by_tenant/1`, and
  `verify_realm_ownership/2` (below) port `src/oidc/realm_tenant_binding.zig`
  and the realm-ownership guard from
  `src/design/adp-04b-tenant-realm-binding.md` /
  `src/design/adp-04a-external-identity-linkage-user.md`'s "Cross-tenant
  collision boundaries" section, operating on REQ-015's `tenants` schema
  (`Letflow.Identity.Tenant`). See
  `lib/letflow/design/req019-tenant-realm-binding.md` for the full design
  these three functions implement.

  Matches this project's established `Letflow.RowApproval`-style pattern: a
  top-level context module in `lib/letflow/`, backed by schema files in a
  same-named subdirectory (`lib/letflow/identity/user.ex` and friends).

  See `lib/letflow/design/req018-jit-provisioning.md` for the full design this
  module implements.

  `create_user/2`, `list_users/2`, `get_user/2`, `update_user_profile/3`, and
  `update_user_status/3` (below) are REQ-073's additions — the first
  general user-CRUD functions on this module, backing the five
  `Letflow.Routers.Identity` route handlers. See
  `lib/letflow/design/req073-identity-user-routes.md` §7 for the full design.
  Each takes `opts :: [prefix: String.t()]`, matching this module's existing
  convention — `:prefix` is always derived by the caller from
  `Letflow.Api.Context.scoped_repo_opts/1`, never supplied by request data.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Repo

  @type provisioning_error ::
          :jit_disabled
          | :realm_tenant_mismatch
          | :external_identity_collision
          | Ecto.Changeset.t()
          | term()

  @typedoc """
  Keyword opts threaded into every `Repo` call in `provision_oidc_user/4`'s call
  chain, matching `lib/letflow/definitions.ex`'s established `opts :: [prefix:
  String.t()]` convention. `:prefix` is required (no default) — see
  `provision_oidc_user/4`'s own @doc for why a missing prefix must never silently
  fall back to the (post-REQ-063) no-longer-authoritative `public` schema.
  """
  @type opts :: [prefix: String.t()]

  @doc """
  Idempotent upsert keyed on `(tenant_id, external_realm, external_id)`:
  returns the existing user if one already matches that triple, otherwise
  creates one. `tenant_id` is trusted as already-resolved/authoritative by the
  caller (REQ-019/021's territory) — it is not read from
  `identity_context.tenant_id` (the token-claimed hint, not the authoritative
  value) and not re-derived or cross-checked here.

  `opts[:prefix]` (required, no default) selects which tenant schema's `users`
  table this call targets — REQ-063 moved `users`/`groups`/`tenant_role` out of
  the public schema into each tenant's own schema, so a caller that omitted this
  would resolve against `public`, which no longer holds `users` once the
  Decision 0006 D1 cutover's drop migration has run. The one caller
  (`Letflow.Plugs.AuthPipeline.provision_user/3`) derives this value via
  `Letflow.TenantProvisioning.schema_name_for_tenant/1` on its own
  already-resolved `tenant_id`, never from a caller-supplied/external value.

  Returns `{:ok, %{user: user, created: created?}}` on success, where
  `created?` is `true` only when this call actually inserted the row (`false`
  on every subsequent call for the same identity). Always returns
  `{:error, reason}` on failure — never raises on a realistic failure path
  (JIT-disabled, changeset validation failure including a `username`
  collision, or the conflict-race fallback).
  """
  @spec provision_oidc_user(
          identity_context :: IdentityContext.t(),
          tenant_id :: Ecto.UUID.t(),
          jit_config :: JitProvisioningConfig.t(),
          opts :: opts()
        ) ::
          {:ok, %{user: User.t(), created: boolean()}}
          | {:error, provisioning_error()}
  def provision_oidc_user(
        %IdentityContext{} = identity_context,
        tenant_id,
        %JitProvisioningConfig{} = jit_config,
        opts
      ) do
    if jit_config.enabled do
      upsert_by_external_identity(identity_context, tenant_id, jit_config, opts)
    else
      {:error, :jit_disabled}
    end
  end

  @doc """
  Resolves the tenant bound to a given IdP realm. This is the authoritative
  reverse path from a token's realm claim to a tenant — REQ-021's future
  pipeline calls this before resolving/provisioning the user, and does not
  resolve tenant identity from a client-supplied `tenant_id` claim directly.

  Returns `{:error, :not_found}` if no tenant is bound to `idp_realm_id`.
  """
  @spec resolve_tenant_by_realm(idp_realm_id :: String.t()) ::
          {:ok, Tenant.t()} | {:error, :not_found}
  def resolve_tenant_by_realm(idp_realm_id) do
    case Repo.get_by(Tenant, idp_realm_id: idp_realm_id) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Resolves the IdP realm bound to a given tenant ID.

  Returns `{:ok, nil}` if the tenant exists but has no bound realm (a
  legitimate state for a non-default tenant created while OIDC is disabled —
  not an error). Returns `{:error, :not_found}` if no tenant with that ID
  exists.
  """
  @spec resolve_realm_by_tenant(tenant_id :: Ecto.UUID.t()) ::
          {:ok, String.t() | nil} | {:error, :not_found}
  def resolve_realm_by_tenant(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{idp_realm_id: idp_realm_id} -> {:ok, idp_realm_id}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Realm-ownership guard: verifies that `external_realm` (a token-claimed,
  untrusted value) is actually the realm bound to the already-resolved,
  trusted `tenant_id`. Called by REQ-021's future pipeline before
  `provision_oidc_user/3`, per adp-04a's "Cross-tenant collision boundaries."

  Re-queries the tenant's bound realm from the database itself (via
  `resolve_realm_by_tenant/1`) rather than trusting a caller-supplied realm
  value — a guard that trusted the same claim it's meant to check would be a
  no-op.

  Returns `:ok` if `external_realm` matches the tenant's bound realm.
  Returns `{:error, :realm_tenant_mismatch}` if the tenant exists but its
  bound realm is `nil` or differs from `external_realm`. Returns
  `{:error, :not_found}` if `tenant_id` does not correspond to any tenant.
  """
  @spec verify_realm_ownership(tenant_id :: Ecto.UUID.t(), external_realm :: String.t()) ::
          :ok | {:error, :realm_tenant_mismatch} | {:error, :not_found}
  def verify_realm_ownership(tenant_id, external_realm) do
    case resolve_realm_by_tenant(tenant_id) do
      {:ok, ^external_realm} -> :ok
      {:ok, _mismatched_or_nil} -> {:error, :realm_tenant_mismatch}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @typedoc "Params accepted by `list_users/2` — see its own @doc."
  @type list_users_params :: %{
          optional(:search) => String.t() | nil,
          optional(:status) => :active | :inactive | nil,
          optional(:cursor) => Pagination.Cursor.t() | nil,
          optional(:page_size) => pos_integer()
        }

  @doc """
  Inserts a new internally-created (non-OIDC) user. Ports
  `identity_service.createUser` per
  `lib/letflow/design/req073-identity-user-routes.md` §7 gap 1 — thin,
  changeset + `Repo.insert/2`, no business logic beyond that.

  `attrs` is a caller-validated map (`Letflow.Api.Validation.validate/2`'s
  output, already restricted to the schema's own named fields) with keys
  `"username"`/`"display_name"`/`"email"`/optionally `"status"`.

  Returns `{:error, :duplicate_username}` on a `username` unique-constraint
  violation (mirrors `username_unique_conflict?/1`'s existing check), or
  `{:error, Ecto.Changeset.t()}` for any other changeset failure.
  """
  @spec create_user(attrs :: map(), opts :: opts()) ::
          {:ok, User.t()} | {:error, :duplicate_username} | {:error, Ecto.Changeset.t()}
  def create_user(attrs, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    changeset = User.create_changeset(%User{}, attrs)

    case Repo.insert(changeset, prefix: prefix) do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        if username_unique_conflict?(changeset) do
          {:error, :duplicate_username}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Lists users, filtered by an optional `status` and an optional `search`
  substring (ILIKE across `username`/`display_name`/`email` — design §7 gap 2,
  OQ-4's field-scope choice), cursor-paginated via `Letflow.Api.Pagination`.

  Sorted by `inserted_at` ascending, then `id` ascending as a tiebreaker (OQ-1).
  The minted cursor's freshness (24h expiry) is checked against the wall-clock
  time the cursor was built, not against a row's own `inserted_at` — see
  `build_next_cursor/1`'s comment for why conflating the two would make an
  old row's cursor appear pre-expired the instant it's minted.

  Always returns `{:ok, _}` — an empty or last page is
  `{:ok, %{users: [], next_cursor: nil}}`, never an error tuple.
  """
  @spec list_users(list_users_params(), opts :: opts()) ::
          {:ok, %{users: [User.t()], next_cursor: String.t() | nil}}
  def list_users(params, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    query =
      User
      |> filter_by_status(Map.get(params, :status))
      |> filter_by_search(Map.get(params, :search))
      |> filter_by_cursor(Map.get(params, :cursor))
      |> order_by([u], asc: u.inserted_at, asc: u.id)
      |> limit(^(page_size + 1))

    rows = Repo.all(query, prefix: prefix)
    {page, next_cursor} = split_page(rows, page_size)

    {:ok, %{users: page, next_cursor: next_cursor}}
  end

  @doc """
  Fetches a single user by id, scoped to the caller's own tenant schema via
  `opts[:prefix]`. Design §7 gap 3 — the shared lookup every handler
  (including the patch/status-update pre-fetch) uses.
  """
  @spec get_user(id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
          {:ok, User.t()} | {:error, :not_found}
  def get_user(id, opts) do
    case Repo.get(User, id, prefix: Keyword.fetch!(opts, :prefix)) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Partial-update of a user's profile fields (`display_name`/`email`/`status`
  — all optional). Design §7 gap 4. `attrs` carries only the keys present in
  the request body; an omitted field's existing value is preserved by
  `Ecto.Changeset.cast/3`'s own behavior over an already-loaded struct.
  """
  @spec update_user_profile(id :: Ecto.UUID.t(), attrs :: map(), opts :: opts()) ::
          {:ok, User.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def update_user_profile(id, attrs, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(User, id, prefix: prefix) do
      nil ->
        {:error, :not_found}

      %User{} = user ->
        user
        |> User.profile_changeset(attrs)
        |> Repo.update(prefix: prefix)
    end
  end

  @doc """
  Updates a user's `status` only. Design §7 gap 5 (OQ-5 — a dedicated
  `User.status_changeset/2` rather than reusing `profile_changeset/2`, see
  that function's own @doc).
  """
  @spec update_user_status(id :: Ecto.UUID.t(), status :: :active | :inactive, opts :: opts()) ::
          {:ok, User.t()} | {:error, :not_found} | {:error, Ecto.Changeset.t()}
  def update_user_status(id, status, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Repo.get(User, id, prefix: prefix) do
      nil ->
        {:error, :not_found}

      %User{} = user ->
        user
        |> User.status_changeset(%{status: status})
        |> Repo.update(prefix: prefix)
    end
  end

  # ── list_users/2 private helpers ────────────────────────────────────────

  @list_users_cursor_prefix "U:"

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: from(u in query, where: u.status == ^status)

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    like = "%#{search}%"

    from(u in query,
      where: ilike(u.username, ^like) or ilike(u.display_name, ^like) or ilike(u.email, ^like)
    )
  end

  defp filter_by_cursor(query, nil), do: query

  defp filter_by_cursor(query, %Pagination.Cursor{} = cursor) do
    {ts_us, id} = decode_users_cursor(cursor)
    ts = naive_datetime_from_us(ts_us)

    from(u in query,
      where: u.inserted_at > ^ts or (u.inserted_at == ^ts and u.id > ^id)
    )
  end

  # Payload shape: "U:<mint_time_us>:<inserted_at_us>:<id>" — built via
  # Pagination.build_raw_cursor_timestamp_key/4, but with a deliberate
  # field-slot repurposing over its literal parameter names, called out here
  # since it deviates from a literal reading of design §7 gap 2 (flagged in
  # ELIXIR-DEV's handoff, not silent):
  #
  # `decode_cursor/4`'s expiry check reads the timestamp starting at a FIXED
  # byte offset (this router calls it with `byte_size(prefix)`, i.e. right
  # after "U:") and treats it as "when was this cursor minted" for the 24h
  # freshness window (`Letflow.Api.Pagination`'s own moduledoc/design §5.1).
  # A row's `inserted_at` is NOT a safe value to put there: a user created
  # more than 24h ago would make every cursor built from their row appear
  # already-expired the instant it's minted, which is not what AC-level
  # cursor expiry is supposed to mean. So the FIRST field (the
  # `sort_timestamp_us` parameter slot of `build_raw_cursor_timestamp_key/4`)
  # carries the real mint time (`System.system_time(:microsecond)`), and
  # `inserted_at_us`/`id` — this endpoint's actual sort key and tiebreaker —
  # are carried in the `key`/`cursor_created_at_us` slots instead, purely for
  # their textual position in the payload, not their parameter names' literal
  # meaning.
  defp decode_users_cursor(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@list_users_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [_mint_time_us_str, inserted_at_us_str, id_str] = String.split(rest, ":", parts: 3)
    {String.to_integer(inserted_at_us_str), id_str}
  end

  defp split_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_next_cursor(List.last(page))}
  end

  defp split_page(rows, _page_size), do: {rows, nil}

  defp build_next_cursor(%User{id: id, inserted_at: inserted_at}) do
    mint_time_us = System.system_time(:microsecond)
    inserted_at_us = us_from_naive_datetime(inserted_at)

    @list_users_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, inserted_at_us, id)
    |> Pagination.encode_cursor()
  end

  defp us_from_naive_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp naive_datetime_from_us(us) when is_integer(us) do
    us
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_naive()
  end

  # The upsert algorithm — select-first / INSERT ... ON CONFLICT ... DO
  # NOTHING / re-select-on-conflict, matching registry.zig lines 843-912
  # exactly. Deliberately not Ecto.Multi (this is one logical conditional
  # insert, not several writes needing transactional composition) and
  # deliberately not a naive insert-then-rescue-unique-constraint-error
  # pattern (that would change the concurrency semantics R-Co's own
  # implementation chose) — see
  # lib/letflow/design/req018-jit-provisioning.md §3.
  defp upsert_by_external_identity(identity_context, tenant_id, jit_config, opts) do
    case get_by_external_identity(tenant_id, identity_context, opts) do
      %User{} = existing ->
        {:ok, %{user: existing, created: false}}

      nil ->
        insert_or_fetch(identity_context, tenant_id, jit_config, opts)
    end
  end

  defp insert_or_fetch(identity_context, tenant_id, jit_config, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    attrs = %{
      external_realm: identity_context.realm,
      external_id: identity_context.external_user_id,
      username: identity_context.preferred_username,
      display_name: identity_context.display_name || identity_context.preferred_username,
      email: identity_context.email,
      status: jit_config.default_status
    }

    changeset = User.jit_changeset(%User{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target:
             {:unsafe_fragment, "(external_realm, external_id) WHERE external_id IS NOT NULL"},
           returning: true,
           prefix: prefix
         ) do
      {:ok, %User{id: id} = inserted} ->
        # Empirically verified against real Postgres (see handoff notes):
        # with this schema's client-generated binary_id primary key,
        # Repo.insert/2 + on_conflict: :nothing + returning: true does NOT
        # distinguish "genuinely inserted" from "suppressed by ON CONFLICT DO
        # NOTHING" anywhere in the returned {:ok, struct} — every field,
        # including the primary key, is padded from the changeset's own
        # locally-known data when the database's RETURNING clause yields zero
        # rows, so a suppressed insert and a real one produce
        # struct-for-struct identical {:ok, %User{}} results. The design's
        # anticipated `id: nil` signal does not occur for this schema (it
        # would only occur for a server-generated, e.g. serial, primary key).
        # The only reliable way to tell them apart is to check whether a row
        # with our own freshly-generated id actually exists in the database —
        # Repo.get/2 on the primary key is the cheapest form of that check.
        if Repo.get(User, id, prefix: prefix) do
          {:ok, %{user: inserted, created: true}}
        else
          re_select_on_conflict(tenant_id, identity_context, opts)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        if username_unique_conflict?(changeset) do
          # Opponent may have raced us with the identical (external_realm,
          # external_id, username) triple -- find out who actually holds
          # that username now. Postgres's on_conflict: :nothing above only
          # names the (external_realm, external_id) arbiter, so a losing
          # racer can raise on the separate `username` unique index instead
          # -- see lib/letflow/design/iss-0047-username-race-conflict-target.md.
          case get_by_username(identity_context.preferred_username, opts) do
            %User{} = holder ->
              if identity_matches?(holder, identity_context) do
                # Same identity as ours -> this is our own race opponent,
                # already persisted. Resolve exactly like the
                # already-working on_conflict path does.
                re_select_on_conflict(tenant_id, identity_context, opts)
              else
                # A DIFFERENT identity already holds this username ->
                # genuine, unrelated collision. Propagate the original
                # changeset error unchanged.
                {:error, changeset}
              end

            nil ->
              # Should not happen (Repo.insert/2 just told us a username
              # conflict occurred) but handled defensively rather than
              # assumed unreachable, matching this module's existing
              # defensive-fallback discipline. Propagate the original
              # error -- do not fabricate a {:ok, _} result for a row this
              # call cannot actually locate.
              {:error, changeset}
          end
        else
          # Not a username-constraint error at all -> unchanged existing
          # behavior.
          {:error, changeset}
        end
    end
  end

  @spec username_unique_conflict?(changeset :: Ecto.Changeset.t()) :: boolean()
  defp username_unique_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:username, {_message, keyword}} -> Keyword.get(keyword, :constraint) == :unique
      _other -> false
    end)
  end

  defp re_select_on_conflict(tenant_id, identity_context, opts) do
    case get_by_external_identity(tenant_id, identity_context, opts) do
      %User{} = existing ->
        {:ok, %{user: existing, created: false}}

      nil ->
        {:error, :external_identity_collision}
    end
  end

  # `tenant_id` is accepted here (and by every caller above) only because the
  # upsert-key contract predates Decision 0006 D2 -- see this function's
  # callers' own `tenant_id` parameter threading, unchanged by D2. The actual
  # `Repo.get_by/3` filter below no longer includes `tenant_id:` because
  # `users.tenant_id` was dropped (Decision 0006 D2, REQ-064): the per-tenant
  # Postgres schema (`prefix:` below) already scopes this lookup to exactly
  # one tenant, so filtering on the now-removed column would raise
  # Ecto.QueryError instead of narrowing anything real.
  defp get_by_external_identity(_tenant_id, identity_context, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    Repo.get_by(
      User,
      [
        external_realm: identity_context.realm,
        external_id: identity_context.external_user_id
      ],
      prefix: prefix
    )
  end

  # Same tenant-scoping discipline as get_by_external_identity/3, keyed on
  # `username` instead of `(external_realm, external_id)`. users.username's
  # unique index is per-schema (Decision 0006/REQ-063), so this lookup is
  # automatically tenant-scoped by virtue of targeting the same `prefix:`
  # the failed insert itself used.
  @spec get_by_username(username :: String.t(), opts :: opts()) :: User.t() | nil
  defp get_by_username(username, opts) do
    Repo.get_by(User, [username: username], prefix: Keyword.fetch!(opts, :prefix))
  end

  @spec identity_matches?(user :: User.t(), identity_context :: IdentityContext.t()) ::
          boolean()
  defp identity_matches?(%User{} = user, %IdentityContext{} = identity_context) do
    user.external_realm == identity_context.realm and
      user.external_id == identity_context.external_user_id
  end
end
