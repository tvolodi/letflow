defmodule Letflow.Support.PlatformTenantFixture do
  @moduledoc """
  Test-only fixture for ISS-0993 / ISS-0994 platform-scope tests
  (`lib/letflow/design/iss0993-platform-scope-separation.md` section 12, "Fixtures").

  Provides:

    * `pin!/1` / `unpin!/0` / `with_platform_tenant!/2` -- set or clear the
      configuration-pinned platform tenant
      (`config :letflow, Letflow.PlatformTenant, tenant_id: ...`) around a test. The original
      value is restored by an `on_exit/1` registered at the first `pin!/1` or `unpin!/0` call,
      so a failing test cannot leak a pin into another module. Application config is
      VM-global: every module using this helper must be `async: false`.
    * `three_tenants!/0` / `two_tenants!/0` -- provisioned tenants P (platform), A (ordinary),
      B (other ordinary) through `Letflow.TenantFixture`.
    * `auth_context/2`, `router_conn/5` -- the hand-assigned `auth_context` style every router
      test in this suite uses (no scope-fact keys on purpose: the plug recomputes them).
    * `mint_token!/2`, `api_conn/5` -- a real API token for a fresh user of a fixture tenant,
      and a request carrying it for the full `Letflow.Router` pipeline.
    * `capture_repo_queries/1`, `touches_tenant?/2` -- the `[:letflow, :repo, :query]` events issued
      by the calling process while `fun` runs, and whether one of them reads/writes a given tenant
      (its schema name appears in the SQL text, or its id in the bound parameters). Used to prove
      that a denied request never queried the named tenant's schema.
  """

  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.User
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @config_key Letflow.PlatformTenant

  @type fixture :: TenantFixture.tenant_fixture()

  # --- Pin management -------------------------------------------------------

  @doc """
  Pins `tenant_id` as the platform tenant (or clears the pin with `nil`) for the rest of the
  calling test. Registers the restore on the first call within a test process.
  """
  @spec pin!(String.t() | nil) :: :ok
  def pin!(tenant_id) do
    ensure_restore!()
    Application.put_env(:letflow, @config_key, tenant_id: tenant_id)
    :ok
  end

  @doc "Clears the platform tenant pin for the rest of the calling test (nobody has platform scope)."
  @spec unpin!() :: :ok
  def unpin!, do: pin!(nil)

  @doc "Runs `fun` with `tenant_id` pinned; the previous config is restored afterwards, even on a raise."
  @spec with_platform_tenant!(String.t() | nil, (-> result)) :: result when result: term()
  def with_platform_tenant!(tenant_id, fun) when is_function(fun, 0) do
    original = Application.fetch_env(:letflow, @config_key)

    try do
      Application.put_env(:letflow, @config_key, tenant_id: tenant_id)
      fun.()
    after
      restore(original)
    end
  end

  defp ensure_restore! do
    key = {__MODULE__, :restore_registered}

    if Process.get(key) != true do
      Process.put(key, true)
      original = Application.fetch_env(:letflow, @config_key)
      ExUnit.Callbacks.on_exit(fn -> restore(original) end)
    end
  end

  defp restore({:ok, value}), do: Application.put_env(:letflow, @config_key, value)
  defp restore(:error), do: Application.delete_env(:letflow, @config_key)

  # --- Tenants --------------------------------------------------------------

  @doc "Two provisioned ordinary tenants, `%{a: fixture, b: fixture}`."
  @spec two_tenants!() :: %{a: fixture(), b: fixture()}
  def two_tenants! do
    %{
      a: TenantFixture.provisioned_tenant!(slug_prefix: "scope-a"),
      b: TenantFixture.provisioned_tenant!(slug_prefix: "scope-b")
    }
  end

  @doc "Three provisioned tenants, `%{p: platform candidate, a: ordinary, b: other ordinary}`."
  @spec three_tenants!() :: %{p: fixture(), a: fixture(), b: fixture()}
  def three_tenants! do
    Map.put(two_tenants!(), :p, TenantFixture.provisioned_tenant!(slug_prefix: "scope-p"))
  end

  # --- Requests -------------------------------------------------------------

  @doc "A hand-assigned `auth_context` (no scope-fact keys) for `fixture` holding `roles`."
  @spec auth_context(fixture() | nil, [String.t()]) :: map()
  def auth_context(fixture, roles) do
    tenant_id = if fixture, do: fixture.tenant_id, else: Ecto.UUID.generate()
    %{user_id: Ecto.UUID.generate(), tenant_id: tenant_id, roles: roles}
  end

  @doc """
  ISS-0993 (A2) helper for the EXISTING platform-route suites that hand-assign an `auth_context`:
  when `roles` include `"PLATFORM_ADMIN"` the caller is the platform operator, so `tenant_id` is
  pinned as THE platform tenant (restored by the fixture's `on_exit`); any other role set is left
  unpinned and is denied by the platform gate. Returns the `auth_context` map.
  """
  @spec operator_auth_context(String.t(), String.t(), [String.t()]) :: map()
  def operator_auth_context(user_id, tenant_id, roles) do
    if "PLATFORM_ADMIN" in roles, do: pin!(tenant_id)
    %{user_id: user_id, tenant_id: tenant_id, roles: roles}
  end

  @doc """
  A `Plug.Test` connection for direct dispatch into one router's `call/2`
  (path relative to that router's mount), carrying a hand-assigned `auth_context`.
  """
  @spec router_conn(atom(), String.t(), fixture() | nil, [String.t()], map() | nil) ::
          Plug.Conn.t()
  def router_conn(method, path, fixture, roles, body) do
    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, auth_context(fixture, roles))
    |> assign(:trace_id, "platform-scope-test-trace-id")
  end

  @doc """
  Mints a real API token for a fresh active user of `fixture`, holding exactly `roles`.

  REQ-447 PR 2: `Identity.create_token/3` refuses `PLATFORM_ADMIN` outside the platform tenant's
  schema. When `roles` contains `"PLATFORM_ADMIN"` and `fixture` is not the pinned platform tenant
  at call time, the token is inserted RAW instead, exactly as a pre-REQ-447 row would exist, so a
  test can prove that such a stored legacy token now holds nothing at request time. Use
  `"TENANT_ADMIN"` for an ordinary tenant's administrator.
  """
  @spec mint_token!(fixture(), [String.t()]) :: String.t()
  def mint_token!(fixture, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "scope-caller-#{Ecto.UUID.generate()}",
        display_name: "Scope Test Caller",
        email: "scope-caller-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: fixture.schema_name)

    if "PLATFORM_ADMIN" in roles and not PlatformTenant.platform_prefix?(fixture.schema_name) do
      insert_legacy_token!(user, roles, fixture.schema_name)
    else
      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: roles, expires_at: nil},
          prefix: fixture.schema_name
        )

      plaintext
    end
  end

  # A raw, changeset-level token insert (bypasses the create_token/3 platform-tenant gate) in the
  # same shape `Identity.create_token/3` writes: `lf_tok_` + 64 lower-case hex, SHA-256 hex hash.
  defp insert_legacy_token!(user, roles, schema_name) do
    plaintext = "lf_tok_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    token_hash = Base.encode16(:crypto.hash(:sha256, plaintext), case: :lower)

    %ApiToken{}
    |> ApiToken.insert_changeset(%{
      user_id: user.id,
      name: "legacy-" <> String.slice(token_hash, 0, 8),
      token_hash: token_hash,
      roles: roles,
      expires_at: nil
    })
    |> Repo.insert!(prefix: schema_name)

    plaintext
  end

  @doc """
  A request for the FULL `Letflow.Router` pipeline (`/api/v1` prefix is part of `path`),
  authenticated by `token` and addressed to `slug`.
  """
  @spec api_conn(atom(), String.t(), String.t(), String.t(), map() | nil) :: Plug.Conn.t()
  def api_conn(method, path, token, slug, body) do
    conn(method, path, if(body, do: Jason.encode!(body), else: nil))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", slug)
  end

  @doc "The full `Letflow.Router` dispatch of a connection."
  @spec dispatch_api(Plug.Conn.t()) :: Plug.Conn.t()
  def dispatch_api(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  # --- Query capture --------------------------------------------------------

  @doc false
  def handle_query_event(_event, _measurements, metadata, {test_pid, ref}) do
    # `:telemetry` runs handlers in the process that issued the query, so this keeps only the
    # calling test's own queries even though the event is VM-global.
    if self() == test_pid, do: send(test_pid, {:repo_query, ref, metadata})
    :ok
  end

  @doc """
  Runs `fun` and returns `{result, queries}`: the `[:letflow, :repo, :query]` telemetry metadata
  maps of every query issued by the CALLING process while `fun` ran, in order.
  """
  @spec capture_repo_queries((-> result)) :: {result, [map()]} when result: term()
  def capture_repo_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.handle_query_event/4,
      {self(), ref}
    )

    try do
      result = fun.()
      {result, drain_queries(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(ref, acc) do
    receive do
      {:repo_query, ^ref, metadata} -> drain_queries(ref, [metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  True when the captured query `metadata` reads or writes `fixture`'s tenant: its schema name
  appears in the SQL text, or its tenant id (string or 16-byte dumped form) is a bound parameter.
  """
  @spec touches_tenant?(map(), fixture()) :: boolean()
  def touches_tenant?(metadata, fixture) do
    query = Map.get(metadata, :query)
    params = Map.get(metadata, :params) || []
    {:ok, dumped} = Ecto.UUID.dump(fixture.tenant_id)

    (is_binary(query) and String.contains?(query, fixture.schema_name)) or
      Enum.any?(params, &(&1 == fixture.tenant_id or &1 == dumped))
  end
end
