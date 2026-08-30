defmodule Letflow.Webhooks do
  @moduledoc """
  Context module for the `webhook_subscriptions` table's core CRUD:
  `create/2`, `list/1`, `update/3`, `delete/2`. See
  `lib/letflow/design/req181-webhooks-core.md` for the full design this
  module implements. Plain Ecto context module, no process — same shape as
  `Letflow.Dlq`/`Letflow.Tasks`/`Letflow.Identity`.

  **Scope boundary, restated from the design (§0/§4):** this module covers
  only the schema/migration and these four functions plus the private
  `get/2` helper they're proven against. No route, no controller, no Plug
  module — that is REQ-182. No delivery attempts, dispatch, outgoing-payload
  HMAC signing, or the deliveries route — that is REQ-183/REQ-184.

  ## Tenant scoping (INV-1)

  Every function below takes `opts :: [prefix: String.t()]`, `prefix` always
  supplied by the caller (the future REQ-182 route, via
  `Letflow.Api.Context.scoped_repo_opts/1`) — this module never itself
  decides tenant scope, matching every REQ-072+ context module's own
  precedent, restated verbatim from `Letflow.Dlq`'s own moduledoc.

  `tenant_id` is never accepted from caller-supplied attrs — it is always
  derived from `opts[:prefix]` via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, the same
  "derived, never accepted" discipline `Letflow.Dlq.enqueue/2` establishes.

  ## Secret handling (REQ-190, design §5.4 — supersedes the original
  ## SHA-256-hash-only design §2.2)

  `create/2` generates (or accepts a caller-supplied) plaintext secret and
  writes it into the global `secrets` table via `Letflow.Secrets.put/2`
  (namespace `"webhook"`, purpose `:webhook_hmac`) instead of hashing it —
  a one-way hash cannot supply the key material HMAC-SHA256 signing needs
  (`docs/migration/decisions/0016-secrets-storage-backend.md` §F). The
  `Subscription` row stores only `secret_ref`/`secret_key_id` (the
  reference, not the plaintext). The plaintext is still returned exactly
  once, as `hmac_secret_once` in `create/2`'s own return value — no other
  function in this module ever returns it again, and no `Subscription`
  struct field carries it (structurally impossible, see
  `Letflow.Webhooks.Subscription`'s own moduledoc). Both the `secrets` insert
  (global, no prefix) and the `webhook_subscriptions` insert (tenant-scoped,
  `prefix: prefix`) happen inside one `Ecto.Multi`/transaction, so a
  `Subscription` row is never left referencing a `secret_ref` that failed to
  write.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Repo
  alias Letflow.Secrets
  alias Letflow.TenantProvisioning
  alias Letflow.Webhooks.Subscription

  @typedoc "Threaded into every `Repo` call below — `:prefix` derived by the caller from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data."
  @type opts :: [prefix: String.t()]

  @webhook_secret_prefix "lf_whsec_"

  # ===========================================================================
  # create/2 (design §3.1)
  # ===========================================================================

  @type create_attrs :: %{
          required(:target_url) => String.t(),
          optional(:secret) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:event_types) => [String.t()] | nil
        }

  @doc """
  Inserts a new `webhook_subscriptions` row. Always sets `status: :ACTIVE`
  (never caller-settable — `create_attrs()` has no `:status`/`:is_active`
  key at all) and `consecutive_failures: 0`.

  Resolves the plaintext secret: if `attrs[:secret]` is a non-nil, non-empty
  string, uses it verbatim (a caller may bring their own secret); otherwise
  generates one via `:crypto.strong_rand_bytes/1` + `Base.encode16/2`.
  Generates the subscription's own id explicitly (`Ecto.UUID.generate/0`,
  REQ-190 design §5.4 step 2) so it can be used as `Letflow.Secrets.put/2`'s
  `name` before the `Subscription` row itself exists, writes the plaintext
  into the global `secrets` table (namespace `"webhook"`, purpose
  `:webhook_hmac`), then inserts the `Subscription` row referencing the
  returned `secret_ref`/`secret_key_id` — both writes in one
  `Ecto.Multi`/transaction, so a `Subscription` row is never left
  referencing a `secret_ref` that failed to write.

  On success, returns `{:ok, %{subscription: subscription, hmac_secret_once:
  plaintext}}` — the plaintext appears **only** in this one return value,
  this one time. On `Letflow.Secrets.put/2` failure, returns
  `{:error, {:secret_write_failed, reason}}` and no `Subscription` row is
  inserted.
  """
  @spec create(create_attrs(), opts()) ::
          {:ok, %{subscription: Subscription.t(), hmac_secret_once: String.t()}}
          | {:error, {:secret_write_failed, term()}}
          | {:error, Ecto.Changeset.t()}
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      plaintext = resolve_secret_plaintext(attrs)
      subscription_id = Ecto.UUID.generate()
      created_at = current_timestamp()

      Multi.new()
      |> Multi.run(:secret, fn _repo, _changes ->
        Secrets.put(%{
          tenant_id: tenant_id,
          namespace: "webhook",
          name: subscription_id,
          purpose: :webhook_hmac,
          plaintext: plaintext,
          created_by: "system:webhooks.create"
        })
      end)
      |> Multi.run(:subscription, fn repo, %{secret: secret} ->
        insert_attrs = %{
          id: subscription_id,
          tenant_id: tenant_id,
          target_url: Map.get(attrs, :target_url),
          secret_ref: secret.reference,
          secret_key_id: secret.key_id,
          description: Map.get(attrs, :description),
          event_types: Map.get(attrs, :event_types) || [],
          created_at: created_at
        }

        %Subscription{}
        |> Subscription.insert_changeset(insert_attrs)
        |> repo.insert(prefix: prefix)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{subscription: subscription}} ->
          {:ok, %{subscription: subscription, hmac_secret_once: plaintext}}

        {:error, :secret, reason, _changes} ->
          {:error, {:secret_write_failed, reason}}

        {:error, :subscription, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  defp resolve_secret_plaintext(%{secret: secret}) when is_binary(secret) and secret != "" do
    secret
  end

  defp resolve_secret_plaintext(_attrs), do: generate_webhook_secret_plaintext()

  defp generate_webhook_secret_plaintext do
    @webhook_secret_prefix <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  # ===========================================================================
  # list/1 (design §3.2)
  # ===========================================================================

  @doc """
  Plain, non-paginated listing of `webhook_subscriptions`, ordered
  `created_at DESC`. Deliberate divergence from `Letflow.Dlq.list/2`'s
  cursor convention (design §3.2) — `webhooksApi.list()` takes no query
  parameters at all.

  Tenant-scoped by `opts[:prefix]` alone: `Repo.all(query, prefix: prefix)`
  executes against the caller's own Postgres schema, which never contains
  another tenant's rows (schema-per-tenant, Decision B) — not a `WHERE
  tenant_id = ...` filter that could be omitted by mistake.
  """
  @spec list(opts()) :: {:ok, [Subscription.t()]}
  def list(opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    subscriptions =
      Subscription
      |> order_by([s], desc: s.created_at)
      |> Repo.all(prefix: prefix)

    {:ok, subscriptions}
  end

  # ===========================================================================
  # update/3 (design §3.3)
  # ===========================================================================

  @type update_attrs :: %{
          optional(:status) => String.t(),
          optional(:is_active) => boolean()
        }

  @doc """
  Reconciles `%{status: "ACTIVE" | "PAUSED"}` and/or `%{is_active:
  boolean()}` to one stored `status` (design §3.3's reconciliation table).
  Resolves the two inputs to a single target atom *before* touching the
  database — the transaction below either has one unambiguous target or
  never starts.

  Row-locked via `SELECT ... FOR UPDATE` then an in-Elixir comparison of
  current vs. target status to decide the `paused_at` effect, then a single
  conditional `status_changeset/2` update — the same lock-then-check idiom
  `Letflow.Dlq.retry/2`/`discard/2` establish.

  `id`/not-found handling mirrors `Letflow.Dlq.get/2` exactly:
  `Ecto.UUID.cast/1` first (`{:error, :invalid_id}`, no DB round-trip), then
  a row-lock-and-fetch scoped to `opts[:prefix]` (`{:error, :not_found}`
  when absent).
  """
  @spec update(id :: String.t(), update_attrs(), opts()) ::
          {:ok, Subscription.t()}
          | {:error, :invalid_id}
          | {:error, :not_found}
          | {:error, :invalid_status}
          | {:error, Ecto.Changeset.t()}
  def update(id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, id} <- cast_subscription_id(id),
         {:ok, target_status} <- reconcile_status(attrs) do
      Multi.new()
      |> Multi.run(:subscription, fn repo, _changes ->
        fetch_and_lock_subscription(repo, id, prefix)
      end)
      |> Multi.run(:apply, fn _repo, %{subscription: subscription} ->
        apply_status_update(subscription, target_status, prefix)
      end)
      |> Repo.transaction()
      |> unwrap_write_result()
    end
  end

  @spec reconcile_status(update_attrs()) :: {:ok, :ACTIVE | :PAUSED} | {:error, :invalid_status}
  defp reconcile_status(%{status: status, is_active: is_active}) do
    with {:ok, from_status} <- status_string_to_atom(status),
         {:ok, from_is_active} <- is_active_to_atom(is_active) do
      if from_status == from_is_active do
        {:ok, from_status}
      else
        {:error, :invalid_status}
      end
    end
  end

  defp reconcile_status(%{status: status}) do
    status_string_to_atom(status)
  end

  defp reconcile_status(%{is_active: is_active}) do
    is_active_to_atom(is_active)
  end

  defp reconcile_status(_attrs), do: {:error, :invalid_status}

  defp status_string_to_atom("ACTIVE"), do: {:ok, :ACTIVE}
  defp status_string_to_atom("PAUSED"), do: {:ok, :PAUSED}
  defp status_string_to_atom(_other), do: {:error, :invalid_status}

  defp is_active_to_atom(true), do: {:ok, :ACTIVE}
  defp is_active_to_atom(false), do: {:ok, :PAUSED}
  defp is_active_to_atom(_other), do: {:error, :invalid_status}

  defp apply_status_update(%Subscription{status: :ACTIVE} = subscription, :ACTIVE, prefix) do
    subscription
    |> Subscription.status_changeset(%{status: :ACTIVE, paused_at: nil})
    |> Repo.update(prefix: prefix)
  end

  defp apply_status_update(%Subscription{status: :PAUSED} = subscription, :ACTIVE, prefix) do
    subscription
    |> Subscription.status_changeset(%{status: :ACTIVE, paused_at: nil})
    |> Repo.update(prefix: prefix)
  end

  defp apply_status_update(%Subscription{status: :PAUSED} = subscription, :PAUSED, _prefix) do
    # Idempotent re-pause: preserve the original pause moment, no write needed.
    {:ok, subscription}
  end

  defp apply_status_update(%Subscription{status: :ACTIVE} = subscription, :PAUSED, prefix) do
    subscription
    |> Subscription.status_changeset(%{status: :PAUSED, paused_at: current_timestamp()})
    |> Repo.update(prefix: prefix)
  end

  # ===========================================================================
  # delete/2 (design §3.4)
  # ===========================================================================

  @doc """
  Tenant-scoped hard delete — no soft-delete/tombstone column exists on this
  schema. `id` validation and not-found handling mirror `update/3`'s own:
  `Ecto.UUID.cast/1` first, then a scoped fetch; if the row is absent (never
  existed, already deleted, or belongs to a different tenant's schema),
  `{:error, :not_found}` — structurally impossible to return a "duplicate
  success," since there is no row left to re-delete.
  """
  @spec delete(id :: String.t(), opts()) ::
          {:ok, Subscription.t()}
          | {:error, :invalid_id}
          | {:error, :not_found}
  def delete(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, subscription} <- get(id, opts) do
      Repo.delete(subscription, prefix: prefix)
    end
  end

  # ===========================================================================
  # get/2 (design §3.5, private helper)
  # ===========================================================================

  @spec get(id :: String.t(), opts()) ::
          {:ok, Subscription.t()} | {:error, :invalid_id | :not_found}
  defp get(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        case Repo.get(Subscription, id, prefix: prefix) do
          nil -> {:error, :not_found}
          %Subscription{} = subscription -> {:ok, subscription}
        end
    end
  end

  # ── shared helpers ──────────────────────────────────────────────────────

  defp cast_subscription_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_id}
    end
  end

  defp fetch_and_lock_subscription(repo, id, prefix) do
    Subscription
    |> where([s], s.id == ^id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :not_found}
      %Subscription{} = subscription -> {:ok, subscription}
    end
  end

  defp unwrap_write_result({:ok, %{apply: subscription}}), do: {:ok, subscription}
  defp unwrap_write_result({:error, _failed_step, reason, _changes}), do: {:error, reason}

  defp current_timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
