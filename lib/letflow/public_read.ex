defmodule Letflow.PublicRead do
  @moduledoc """
  The unauthenticated-read platform machinery (REQ-352, design
  `lib/letflow/design/req352-unauthenticated-read-platform.md`), building the
  first concrete artefacts of the pattern fixed by
  `lib/letflow/design/req323-unauthenticated-read-pattern.md` and decision
  `docs/migration/decisions/0028-unauthenticated-read-boundary.md`.

  Two halves live in this one context module, deliberately: `issue_handle/4`
  (the authenticated writer) and `resolve/2` (the unauthenticated reader),
  because both sides of the registry belong together. This module registers
  no `<kind>` of its own and ships no projection for any real resource --
  see `Letflow.PublicRead.Projection`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Identity.Tenant
  alias Letflow.PublicRead.Handle
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type issue_opts :: [expires_at: DateTime.t() | nil]

  # ── Writer (§5) ─────────────────────────────────────────────────────────

  @doc """
  Mints a new opaque capability handle for `{tenant_id, kind, resource_id}`
  and stores its hash only -- the plaintext is returned exactly once, here,
  and is never persisted (design §5, mirroring
  `Letflow.Identity.insert_token/3`'s mint -> hash -> `Ecto.Multi` -> single
  transaction shape).

  `tenant_id` MUST be a real, already-provisioned tenant id -- this function
  derives that tenant's schema prefix internally (for the accompanying audit
  entry) via `Letflow.TenantProvisioning.schema_name_for_tenant/1`, which is
  pure and total over any syntactically valid UUID; an invalid `tenant_id`
  here indicates a caller bug (every real caller reads it from
  `conn.assigns.auth_context.tenant_id`, itself always a genuine tenant id),
  so that case raises rather than being folded into `{:error, _}`.
  """
  @spec issue_handle(
          tenant_id :: Ecto.UUID.t(),
          kind :: String.t(),
          resource_id :: Ecto.UUID.t(),
          opts :: issue_opts()
        ) ::
          {:ok, %{handle: String.t(), record: Handle.t()}}
          | {:error, Ecto.Changeset.t()}
  def issue_handle(tenant_id, kind, resource_id, opts \\ []) do
    prefix =
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, prefix} ->
          prefix

        {:error, :invalid_tenant_id} ->
          raise ArgumentError,
                "issue_handle/4 called with an invalid tenant_id: #{inspect(tenant_id)}"
      end

    plaintext = mint_plaintext()
    handle_hash = hash_handle(plaintext)

    changeset =
      Handle.insert_changeset(%Handle{}, %{
        handle_hash: handle_hash,
        tenant_id: tenant_id,
        kind: kind,
        resource_id: resource_id,
        expires_at: Keyword.get(opts, :expires_at)
      })

    Multi.new()
    |> Multi.insert(:handle, changeset)
    |> Multi.merge(fn %{handle: handle} ->
      Audit.append_multi(
        Multi.new(),
        :audit,
        %{
          actor_id: nil,
          action: "public_read_handle.issue",
          resource_type: kind,
          resource_id: handle.resource_id,
          before_state: nil,
          after_state: Audit.struct_state(handle, [:handle_hash]),
          trace_id: nil
        },
        prefix
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{handle: handle}} -> {:ok, %{handle: plaintext, record: handle}}
      {:error, :handle, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, :audit, reason, _changes} -> {:error, reason}
    end
  end

  defp mint_plaintext do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_handle(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  # ── Resolution (§6, §7) ─────────────────────────────────────────────────

  @doc """
  Resolves `handle` against `kind`, per the ten-case refusal table (design
  §7). Exactly one DB round-trip before any refusal decision, exactly two
  on success -- see the design's §6 for the full query plan this function
  implements.

  Case 8 (an unregistered `kind`) is decided first, from application config
  only (zero round-trips, no query issued) -- `Letflow.Routers.PublicRead`
  already performs this same check itself before ever calling this function
  (design §8), so in the normal request path this branch is a no-op repeat
  of a check already passed; it is kept here too so `resolve/2` is correct
  and round-trip-safe when called directly, e.g. from a test.
  """
  @spec resolve(kind :: String.t(), handle :: binary()) ::
          {:ok, %{optional(String.t()) => term()}} | :not_found
  def resolve(kind, handle) do
    case fetch_kind(kind) do
      :error -> :not_found
      {:ok, projection_module} -> resolve_registered(kind, handle, projection_module)
    end
  end

  defp resolve_registered(kind, handle, projection_module) do
    handle_hash = hash_handle(handle)

    query =
      from(h in Handle,
        join: t in Tenant,
        on: t.id == h.tenant_id,
        where: h.handle_hash == ^handle_hash,
        select: %{handle: h, tenant_status: t.status}
      )

    case Repo.one(query) do
      nil -> :not_found
      row -> resolve_row(row, kind, projection_module)
    end
  end

  defp resolve_row(%{handle: handle, tenant_status: tenant_status}, kind, projection_module) do
    cond do
      not is_nil(handle.revoked_at) ->
        :not_found

      not is_nil(handle.expires_at) and
          DateTime.compare(handle.expires_at, DateTime.utc_now()) != :gt ->
        :not_found

      handle.kind != kind ->
        :not_found

      tenant_status == :inactive ->
        :not_found

      true ->
        resolve_resource(handle, kind, projection_module)
    end
  end

  defp resolve_resource(handle, kind, projection_module) do
    case TenantProvisioning.schema_name_for_tenant(handle.tenant_id) do
      {:error, :invalid_tenant_id} ->
        :not_found

      {:ok, prefix} ->
        schema = projection_module.schema()

        case Repo.get(schema, handle.resource_id, prefix: prefix) do
          nil ->
            :not_found

          resource ->
            handle_meta = %{issued_at: handle.inserted_at, kind: handle.kind}

            case projection_module.project(resource, handle_meta) do
              {:ok, data} ->
                {:ok,
                 %{
                   "kind" => kind,
                   "issued_at" => DateTime.to_iso8601(handle.inserted_at),
                   "data" => data
                 }}

              :skip ->
                :not_found
            end
        end
    end
  end

  # ── Kind registry (§8) ──────────────────────────────────────────────────

  @doc """
  Looks up `kind` in the `:public_read_kinds` application config map,
  returning the registered projection module. `Application.fetch_env!/2`
  runs on the config KEY (always present, defaulting to `%{}` -- see
  `config/config.exs`), never on `kind` itself, so this never raises in
  production use: it is `Map.fetch/2` on the returned map that distinguishes
  a registered kind from an unregistered one (design §8).
  """
  @spec fetch_kind(kind :: String.t()) :: {:ok, module()} | :error
  def fetch_kind(kind) do
    :public_read_kinds
    |> then(&Application.fetch_env!(:letflow, &1))
    |> Map.fetch(kind)
  end
end
