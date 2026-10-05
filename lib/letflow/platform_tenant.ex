defmodule Letflow.PlatformTenant do
  @moduledoc """
  The single, configuration-pinned platform tenant (ISS-0993 / ISS-0994, design
  `lib/letflow/design/iss0993-platform-scope-separation.md` sections 3 and 4).

  The pin is deployment configuration, `config :letflow, Letflow.PlatformTenant,
  tenant_id: String.t() | nil`, filled at boot from the environment variable
  `LETFLOW_PLATFORM_TENANT_ID` by `config/runtime.exs` through `parse_env/1`.
  The default is `nil` (config/config.exs). Unset means NOBODY has platform
  scope (fail closed). There is no setter in this module, no table column and
  no route that can write the pin: this module exposes read functions only.

  `platform_scope?` is `platform_tenant?` AND the caller holds `:PLATFORM_ADMIN`
  in the effective roles the authentication pipeline resolved from the
  database. Every consumer RECOMPUTES it through `platform_tenant?/1`,
  `scope_facts/2` or `scope_facts_for/1`; the keys the pipeline stores in
  `conn.assigns.auth_context` are informational only and are never read for a
  decision (and never by dot access: a hand-assigned context without them
  stays fail-closed and cannot raise).

  Nothing in this module logs a tenant id, a role or a token.

  ## Open decision points (one line each; a ruling changes a line)

    * `cross_tenant_promotion_operator_only?/0` -- OQ-2
    * `Letflow.Api.Authorization.tenant_platform_admin_own_tenant_powers?/0` -- C6
  """

  alias Letflow.Api.Authorization

  require Logger

  @uuid_re ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @type facts :: %{platform_tenant?: boolean(), platform_scope?: boolean()}

  # --- Open decision points -------------------------------------------------

  @doc """
  OQ-2 (ratified by letflow-9a): reading or writing a tenant OTHER than the
  caller's own (the source/target tenant of a promotion, the source tenant of
  the promote route) is an operator-only action. Own-tenant promotion review,
  approve, reject, apply and definition rollback stay TENANT scope under their
  named permissions. Flip this value to restore the legacy allow-all pairing.
  Consumed by `Letflow.Definitions.PromotionAccess` (wired in A2).
  """
  @spec cross_tenant_promotion_operator_only?() :: boolean()
  def cross_tenant_promotion_operator_only?,
    do: Application.get_env(:letflow, :cross_tenant_promotion_operator_only, true) != false

  # OQ-4 (unmatched platform subpaths) and OQ-13 (health/metrics scope) are
  # introduced in A2 where consumed; see the design doc's OQ-4 / OQ-13 sections.

  # --- Configuration --------------------------------------------------------

  @doc """
  Parses the raw `LETFLOW_PLATFORM_TENANT_ID` value. `nil`, empty and
  whitespace-only input is `{:ok, nil}` (unset). A hyphenated UUID, any case,
  is returned canonical lower-case. Anything else is `{:error, :invalid_uuid}`.
  The input is never echoed by this function.
  """
  @spec parse_env(String.t() | nil) :: {:ok, String.t() | nil} | {:error, :invalid_uuid}
  def parse_env(nil), do: {:ok, nil}

  def parse_env(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        {:ok, nil}

      trimmed ->
        if uuid?(trimmed),
          do: {:ok, String.downcase(trimmed)},
          else: {:error, :invalid_uuid}
    end
  end

  def parse_env(_other), do: {:error, :invalid_uuid}

  @doc "True iff the value is a canonical hyphenated UUID string (any case)."
  @spec uuid?(term()) :: boolean()
  def uuid?(value) when is_binary(value), do: Regex.match?(@uuid_re, value)
  def uuid?(_other), do: false

  @doc "The configured platform tenant id (canonical lower-case) or `nil` when unset."
  @spec configured_id() :: String.t() | nil
  def configured_id do
    case :letflow |> Application.get_env(__MODULE__, []) |> Keyword.get(:tenant_id) do
      id when is_binary(id) -> String.downcase(id)
      _unset_or_other -> nil
    end
  end

  # --- Derived facts --------------------------------------------------------

  @doc "True iff a platform tenant is configured and `tenant_id` equals it. False for `nil`."
  @spec platform_tenant?(String.t() | nil) :: boolean()
  def platform_tenant?(tenant_id) when is_binary(tenant_id) do
    case configured_id() do
      nil -> false
      pinned -> String.downcase(tenant_id) == pinned
    end
  end

  def platform_tenant?(_other), do: false

  @doc """
  Both scope facts from a tenant id and the raw role strings. `platform_scope?`
  is `platform_tenant?` AND `:PLATFORM_ADMIN` among the parsed roles.
  """
  @spec scope_facts(String.t() | nil, [String.t()] | term()) :: facts()
  def scope_facts(tenant_id, role_strings) do
    platform_tenant? = platform_tenant?(tenant_id)

    platform_admin? =
      is_list(role_strings) and
        :PLATFORM_ADMIN in Authorization.roles_from_strings(role_strings)

    %{platform_tenant?: platform_tenant?, platform_scope?: platform_tenant? and platform_admin?}
  end

  @doc """
  Recomputes both facts from an `auth_context`-shaped map using `Map.get/3`
  (defaults `nil` and `[]`). A non-map input gives both facts `false`. Never
  reads a stored `platform_tenant?`/`platform_scope?` key.
  """
  @spec scope_facts_for(map() | term()) :: facts()
  def scope_facts_for(auth_context) when is_map(auth_context) do
    scope_facts(Map.get(auth_context, :tenant_id, nil), Map.get(auth_context, :roles, []))
  end

  def scope_facts_for(_other), do: %{platform_tenant?: false, platform_scope?: false}

  # --- Boot-time registration check ----------------------------------------

  @doc """
  One-shot, non-fatal boot check (started as a temporary `Task` child after the
  repo is up): when a pin is configured, a `tenants` row with that id must
  exist; if not, one error log line without the value. Never raises.
  """
  @spec check_registration() :: :ok
  def check_registration do
    case configured_id() do
      nil ->
        :ok

      id ->
        if registered?(id) do
          :ok
        else
          Logger.error("configured platform tenant is not registered")
        end
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp registered?(id) do
    import Ecto.Query, only: [from: 2]

    Letflow.Repo.exists?(from(t in Letflow.Identity.Tenant, where: t.id == ^id))
  end
end
