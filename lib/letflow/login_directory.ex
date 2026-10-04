defmodule Letflow.LoginDirectory do
  @moduledoc """
  Platform tenant-login directory context (REQ-435; design
  `lib/letflow/design/req434-email-first-login-directory.md` §1-§5, decision
  `docs/migration/decisions/0042-email-first-login-tenant-directory.md`).

  Maintains and reads `tenant_login_directory`
  (`Letflow.Identity.TenantLoginDirectoryEntry`): a public-schema pointer table
  of `(email_key, tenant_id)` pairs answering "which tenants hold an active user
  with this email". It builds only the data layer and its population; the
  limiter, the public lookup route and the SPA are later requirements.

  ## Key form

  `email_key = HMAC-SHA256(pepper, "letflow:login-directory:v1:" <> normalised_email)`,
  32 raw bytes, where the normalised email is
  `Letflow.Identity.TenantMembership.normalize_subject_key/1` (one shared
  implementation, never forked). The pepper is read at the point of use from
  `config :letflow, :login_directory_pepper` (populated at boot from the
  `LETFLOW_LOGIN_DIRECTORY_PEPPER` environment-variable reference by
  `config/runtime.exs`, which fails closed when it is absent). It is never
  logged, never stored in a struct and never returned.

  ## Writers

  `upsert_entry/2` and `remove_entry_if_unreferenced/3` must run inside a
  transaction (they return `{:error, :not_in_transaction}` otherwise) and take a
  transaction-scoped advisory lock per `(tenant_id, email_key)` so concurrent
  decisions observe each other's outcome. `plan_user_change/2` is the pure single
  source of truth for add/remove decisions; `apply_plan/3` executes a plan,
  acquiring every lock in ascending key order first. The callers are the
  `Letflow.Identity` user functions, in the same transaction as the user write.

  ## Logging (INV-4)

  Every `Repo` call that touches the directory, or binds a normalised email or
  an `email_key`, passes `log: false`: Ecto's default query log prints bound
  parameters at `:debug`. Telemetry events still fire. No email, key or IP is
  logged, audited or put in telemetry by this module.
  """

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantLoginDirectoryEntry
  alias Letflow.Identity.TenantMembership
  alias Letflow.Identity.User
  alias Letflow.Repo

  @key_domain "letflow:login-directory:v1:"
  # Fixed string no valid address can equal (it contains no "@"); keyed with the
  # same pepper so it costs the same as a real key.
  @sentinel_input "sentinel-no-at-sign"
  @max_email_bytes 255
  @lookup_limit 50
  # First int4 of the two-integer advisory lock: a fixed namespace constant.
  @lock_namespace 435_001

  @type email_key :: <<_::256>>
  @type tenant_ref :: %{slug: String.t(), display_name: String.t()}

  @type plan_step ::
          {:upsert, email :: String.t()}
          | {:remove_if_unreferenced, email :: String.t()}

  # ── keys ────────────────────────────────────────────────────────────────

  @doc """
  The keyed email key for `email`. Returns `:invalid` when `email` is not a
  binary, its trimmed size is outside 1..255 bytes, or it fails
  `TenantMembership.email_shape?/1`; `{:error, :pepper_unavailable}` when the
  pepper is not configured.
  """
  @spec email_key(term()) :: {:ok, email_key()} | :invalid | {:error, :pepper_unavailable}
  def email_key(email) do
    if valid_email?(email) do
      hmac(TenantMembership.normalize_subject_key(email))
    else
      :invalid
    end
  end

  @doc """
  The sentinel key used for malformed input: a keyed HMAC of a fixed string no
  valid address can equal. The writers never write it, so it never matches a row.
  """
  @spec sentinel_key() :: email_key() | {:error, :pepper_unavailable}
  def sentinel_key do
    case hmac(@sentinel_input) do
      {:ok, key} -> key
      {:error, :pepper_unavailable} = error -> error
    end
  end

  defp hmac(normalised) do
    case Application.fetch_env(:letflow, :login_directory_pepper) do
      {:ok, <<_::binary-size(32)>> = pepper} ->
        {:ok, :crypto.mac(:hmac, :sha256, pepper, @key_domain <> normalised)}

      _other ->
        {:error, :pepper_unavailable}
    end
  end

  # Pepper-free validity check, shared by key derivation and the pure plan.
  defp valid_email?(email) when is_binary(email) do
    trimmed = String.trim(email)
    byte_size(trimmed) in 1..@max_email_bytes and TenantMembership.email_shape?(trimmed)
  end

  defp valid_email?(_email), do: false

  # ── read ────────────────────────────────────────────────────────────────

  @doc """
  The one discovery query: the directory joined to `tenants`, for `key`, active
  tenants with a bound (non-empty) `idp_realm_id` only, ordered by `display_name`
  then `slug`, limited to 50. Returns plain maps holding only `slug` and
  `display_name` (the `Tenant` struct is never loaded, so no other field is
  representable past the query). Touches public tables only (no `:prefix`). A
  failure is `{:error, :lookup_failed}`.
  """
  @spec lookup_by_key(email_key()) :: {:ok, [tenant_ref()]} | {:error, :lookup_failed}
  def lookup_by_key(<<_::binary-size(32)>> = key) do
    query =
      from(d in TenantLoginDirectoryEntry,
        join: t in Tenant,
        on: t.id == d.tenant_id,
        where:
          d.email_key == ^key and t.status == :active and not is_nil(t.idp_realm_id) and
            t.idp_realm_id != "",
        order_by: [asc: t.display_name, asc: t.slug],
        limit: @lookup_limit,
        select: %{slug: t.slug, display_name: t.display_name}
      )

    {:ok, Repo.all(query, log: false)}
  rescue
    _exception -> {:error, :lookup_failed}
  end

  def lookup_by_key(_other), do: {:error, :lookup_failed}

  @doc """
  Convenience composition of `email_key/1` and `lookup_by_key/1`: an invalid
  input uses the sentinel key. An unavailable pepper is `{:error, :lookup_failed}`.
  """
  @spec lookup_by_email(term()) :: {:ok, [tenant_ref()]} | {:error, :lookup_failed}
  def lookup_by_email(email) do
    case email_key(email) do
      {:ok, key} ->
        lookup_by_key(key)

      :invalid ->
        case sentinel_key() do
          {:error, :pepper_unavailable} -> {:error, :lookup_failed}
          key -> lookup_by_key(key)
        end

      {:error, :pepper_unavailable} ->
        {:error, :lookup_failed}
    end
  end

  # ── plan ────────────────────────────────────────────────────────────────

  @doc """
  Pure plan function: the single source of truth for what a user change does to
  the directory (design §3.3). A user is eligible when `status == :active` and
  its email is valid. `before` is `nil` for a create.
  """
  @spec plan_user_change(before :: User.t() | nil, after_user :: User.t()) :: [plan_step()]
  def plan_user_change(before, %User{} = after_user) do
    case {eligible?(before), eligible?(after_user)} do
      {false, true} ->
        [{:upsert, after_user.email}]

      {true, false} ->
        [{:remove_if_unreferenced, before.email}]

      {true, true} ->
        if TenantMembership.normalize_subject_key(before.email) ==
             TenantMembership.normalize_subject_key(after_user.email) do
          []
        else
          [{:remove_if_unreferenced, before.email}, {:upsert, after_user.email}]
        end

      {false, false} ->
        []
    end
  end

  defp eligible?(%User{status: :active, email: email}), do: valid_email?(email)
  defp eligible?(_other), do: false

  @doc """
  Executes `plan` for `tenant_id` against the tenant schema `prefix` (used only
  by the removal check). Must run inside a transaction. Acquires the advisory
  lock of every touched key in ascending key-byte order before any step, so two
  concurrent multi-key plans cannot deadlock.
  """
  @spec apply_plan([plan_step()], tenant_id :: Ecto.UUID.t(), prefix :: String.t()) ::
          :ok | {:error, term()}
  def apply_plan([], _tenant_id, _prefix), do: :ok

  def apply_plan(plan, tenant_id, prefix) when is_list(plan) do
    with :ok <- ensure_in_transaction(),
         {:ok, keys} <- plan_keys(plan),
         :ok <- lock_keys(tenant_id, keys) do
      run_steps(plan, tenant_id, prefix)
    end
  end

  defp plan_keys(plan) do
    plan
    |> Enum.reduce_while({:ok, []}, fn {_op, email}, {:ok, acc} ->
      case email_key(email) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        :invalid -> {:halt, {:error, :invalid_email}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, keys |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp lock_keys(tenant_id, keys) do
    Enum.each(keys, &acquire_key_lock(tenant_id, &1))
    :ok
  end

  defp run_steps(plan, tenant_id, prefix) do
    Enum.reduce_while(plan, :ok, fn
      {:upsert, email}, :ok ->
        step_result(upsert_entry(tenant_id, email))

      {:remove_if_unreferenced, email}, :ok ->
        step_result(remove_entry_if_unreferenced(tenant_id, email, prefix))
    end)
  end

  defp step_result({:ok, _outcome}), do: {:cont, :ok}
  defp step_result({:error, _reason} = error), do: {:halt, error}

  # ── writers ─────────────────────────────────────────────────────────────

  @doc """
  Inserts the entry for `(email_key(email), tenant_id)` if absent
  (`ON CONFLICT DO NOTHING`). Must run inside a transaction. Returns
  `{:ok, :inserted | :exists}`, `{:error, :invalid_email}` (nothing written, the
  sentinel is never written), `{:error, :pepper_unavailable}`,
  `{:error, :not_in_transaction}` or `{:error, :write_failed}`.
  """
  @spec upsert_entry(tenant_id :: Ecto.UUID.t(), email :: String.t()) ::
          {:ok, :inserted | :exists}
          | {:error, :invalid_email | :pepper_unavailable | :not_in_transaction | :write_failed}
  def upsert_entry(tenant_id, email) do
    with :ok <- ensure_in_transaction(),
         {:ok, key} <- key_or_error(email),
         :ok <- acquire_key_lock(tenant_id, key) do
      row = %{
        email_key: key,
        tenant_id: tenant_id,
        inserted_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
      }

      case Repo.insert_all(TenantLoginDirectoryEntry, [row],
             on_conflict: :nothing,
             conflict_target: [:email_key, :tenant_id],
             log: false
           ) do
        {1, _} -> {:ok, :inserted}
        {0, _} -> {:ok, :exists}
      end
    end
  rescue
    # Fixed reason only: the exception text must never reach a caller or a log.
    _exception -> {:error, :write_failed}
  end

  @doc """
  Deletes the entry for `(email_key(email), tenant_id)` only if no other active
  user in the tenant schema `prefix` has the same normalised email (design §3.6;
  `users.email` carries no unique index, so two active users can share it). The
  caller has already applied the user write in this transaction, so the check is
  simply "does any active user row still carry this email". Must run inside a
  transaction. Returns `{:ok, :removed | :kept | :absent}` or an error as for
  `upsert_entry/2`.
  """
  @spec remove_entry_if_unreferenced(
          tenant_id :: Ecto.UUID.t(),
          email :: String.t(),
          prefix :: String.t()
        ) ::
          {:ok, :removed | :kept | :absent}
          | {:error, :invalid_email | :pepper_unavailable | :not_in_transaction | :write_failed}
  def remove_entry_if_unreferenced(tenant_id, email, prefix) when is_binary(prefix) do
    with :ok <- ensure_in_transaction(),
         {:ok, key} <- key_or_error(email),
         :ok <- acquire_key_lock(tenant_id, key) do
      normalised = TenantMembership.normalize_subject_key(email)

      still_referenced? =
        Repo.exists?(
          from(u in User,
            where: u.status == :active and fragment("lower(btrim(?))", u.email) == ^normalised
          ),
          prefix: prefix,
          log: false
        )

      if still_referenced? do
        {:ok, :kept}
      else
        {count, _} =
          Repo.delete_all(
            from(d in TenantLoginDirectoryEntry,
              where: d.email_key == ^key and d.tenant_id == ^tenant_id
            ),
            log: false
          )

        if count > 0, do: {:ok, :removed}, else: {:ok, :absent}
      end
    end
  rescue
    _exception -> {:error, :write_failed}
  end

  defp key_or_error(email) do
    case email_key(email) do
      {:ok, key} -> {:ok, key}
      :invalid -> {:error, :invalid_email}
      {:error, _} = error -> error
    end
  end

  defp ensure_in_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :not_in_transaction}
  end

  # Transaction-scoped two-integer advisory lock over (tenant_id, email_key):
  # a fixed namespace constant plus a hash of the pair; a hash collision only
  # over-serialises. Bound parameters only (INV-7); log: false (INV-4).
  defp acquire_key_lock(tenant_id, key) do
    hash = :erlang.phash2({tenant_id, key}, 2_147_483_647)

    Repo.query!("SELECT pg_advisory_xact_lock($1::int, $2::int)", [@lock_namespace, hash],
      log: false
    )

    :ok
  end
end
