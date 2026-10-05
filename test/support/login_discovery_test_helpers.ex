defmodule Letflow.Test.LoginDiscoveryHelpers do
  @moduledoc """
  REQ-437 shared test helpers (test-only; never referenced from `lib/`). Used by
  `test/letflow/routers/login_discovery_test.exs`, `..._timing_test.exs`,
  `test/letflow/login_discovery/dispatch_test.exs` (see `test/specs/REQ-437.md`).

  Everything goes through the real `Letflow.Router` at `/api/login-discovery`, so
  the mount position, `Letflow.Plugs.Cors` and `HttpMetrics` are part of what is
  exercised.

  Tenants are provisioned ONCE per test module (`provision_world!/0`, called from
  `setup_all`): four real tenants named so the lookup's `display_name` ordering is
  Alpha, Bravo, Charlie, Delta. Per-test state (status, stored mode, directory
  rows) is written inside the test's rolled-back sandbox transaction.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity.Tenant
  alias Letflow.LoginDirectory
  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Limiter
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  @router_opts Letflow.Router.init([])
  @mount "/api/login-discovery"
  @table :letflow_login_discovery_rate_limit
  @outcome [:letflow, :login_discovery, :outcome]
  @supervisor Letflow.LoginDiscovery.TaskSupervisor

  @generous [
    global_capacity: 100_000,
    global_refill_per_sec: 1_000,
    ip_capacity: 100_000,
    ip_refill_per_sec: 1_000,
    email_capacity: 100_000,
    email_refill_per_sec: 1_000,
    send_capacity: 100_000,
    send_refill_per_sec: 1_000
  ]

  @type tenant_info :: %{
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t(),
          slug: String.t(),
          display_name: String.t(),
          idp_realm_id: String.t()
        }

  def mount, do: @mount

  # ── provisioning / seeding ──────────────────────────────────────────────

  @names %{a: "R437 Alpha", b: "R437 Bravo", c: "R437 Charlie", d: "R437 Delta"}

  @doc "Provisions the named tenants (a subset of `[:a, :b, :c, :d]`; call from `setup_all`)."
  @spec provision_world!([atom()]) :: %{optional(atom()) => tenant_info()}
  def provision_world!(keys) do
    for key <- keys, into: %{} do
      t = Fx.tenant!(display_name: Map.fetch!(@names, key), slug_prefix: "req437")
      tenant = Letflow.Repo.get!(Tenant, t.tenant_id)

      {key,
       %{
         tenant_id: t.tenant_id,
         schema_name: t.schema_name,
         slug: tenant.slug,
         display_name: tenant.display_name,
         idp_realm_id: tenant.idp_realm_id
       }}
    end
  end

  @doc "Sets (inside the test's sandbox) the stored per-tenant mode column."
  @spec set_mode!(tenant_info(), String.t() | nil) :: :ok
  def set_mode!(%{tenant_id: tenant_id}, mode) do
    import Ecto.Query, only: [from: 2]

    {1, _} =
      Letflow.Repo.update_all(from(t in Tenant, where: t.id == ^tenant_id),
        set: [login_disclosure_mode: mode]
      )

    :ok
  end

  @doc "Sets the tenant status (inside the test's sandbox)."
  @spec set_status!(tenant_info(), :active | :inactive | :migrating) :: :ok
  def set_status!(tenant, status), do: Fx.set_status!(tenant, status)

  @doc "Writes the directory row for `email` under `tenant` (current pepper)."
  @spec add_entry!(tenant_info(), String.t()) :: :ok
  def add_entry!(%{tenant_id: tenant_id}, email) do
    {:ok, {:ok, _}} =
      Letflow.Repo.transaction(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)

    :ok
  end

  @doc "A unique valid address."
  @spec email() :: String.t()
  def email, do: Fx.unique_email("r437")

  @doc "Candidate keys of `email` under the configured pepper(s)."
  @spec keys!(String.t()) :: [binary()]
  def keys!(email) do
    {:ok, keys} = LoginDirectory.email_keys(email)
    keys
  end

  @doc "Makes the lookup query fail for the rest of the test (rolled back with it)."
  @spec break_lookup!() :: :ok
  def break_lookup! do
    Letflow.Repo.query!("SET LOCAL search_path TO pg_catalog")
    :ok
  end

  # ── env ─────────────────────────────────────────────────────────────────

  @doc "Puts an application env value for the test, restored in `on_exit/1`."
  @spec put_env!(atom(), term()) :: :ok
  def put_env!(key, value) do
    original = Application.fetch_env(:letflow, key)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:letflow, key, v)
        :error -> Application.delete_env(:letflow, key)
      end
    end)

    Application.put_env(:letflow, key, value)
  end

  @doc "Deletes an application env key for the test, restored in `on_exit/1`."
  @spec delete_env!(atom()) :: :ok
  def delete_env!(key) do
    original = Application.fetch_env(:letflow, key)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:letflow, key, v)
        :error -> :ok
      end
    end)

    Application.delete_env(:letflow, key)
  end

  @doc "Sets the deployment mode (`Letflow.LoginDiscovery` env), keeping the body bound."
  @spec put_mode!(term()) :: :ok
  def put_mode!(mode) do
    put_env!(Letflow.LoginDiscovery, mode: mode, max_body_bytes: 2048)
  end

  @doc "Enables or disables the mount (`Letflow.Routers.LoginDiscovery` env)."
  @spec put_enabled!(term()) :: :ok
  def put_enabled!(value), do: put_env!(Letflow.Routers.LoginDiscovery, enabled: value)

  @doc """
  Generous limiter budgets (so a test is never throttled by accident), the limiter
  table emptied, no trusted proxy; everything restored in `on_exit/1`. `overrides`
  are merged over the generous base.
  """
  @spec setup_limiter!(keyword()) :: :ok
  def setup_limiter!(overrides) do
    put_env!(Limiter, Keyword.merge(@generous, overrides))
    put_env!(Letflow.Plugs.ClientIp, trusted_proxies: [])
    :ets.delete_all_objects(@table)
    on_exit(fn -> :ets.delete_all_objects(@table) end)
    :ok
  end

  def limiter_table, do: @table

  # ── requests ────────────────────────────────────────────────────────────

  @doc "Runs any conn through the real `Letflow.Router`."
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(conn), do: Letflow.Router.call(conn, @router_opts)

  @doc "POST `{\"email\": email}` as `application/json`."
  @spec post_email(term()) :: Plug.Conn.t()
  def post_email(email), do: post_raw(Jason.encode!(%{"email" => email}), "application/json")

  @doc "POST an arbitrary raw body with the given content type (`nil` = no header)."
  @spec post_raw(binary(), String.t() | nil) :: Plug.Conn.t()
  def post_raw(body, content_type) do
    build_post(body, content_type) |> run()
  end

  @doc "Like `post_raw/2` from a given peer address and extra headers."
  @spec post_from(binary(), :inet.ip_address(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  def post_from(body, ip, headers) do
    conn = build_post(body, "application/json") |> Map.put(:remote_ip, ip)
    headers |> Enum.reduce(conn, fn {k, v}, c -> put_req_header(c, k, v) end) |> run()
  end

  @doc "Any method against the mount (`suffix` appended to the mount path)."
  @spec call(atom() | String.t(), String.t()) :: Plug.Conn.t()
  def call(method, suffix), do: conn(method, @mount <> suffix, "") |> run()

  defp build_post(body, nil), do: conn(:post, @mount, body)

  defp build_post(body, content_type) do
    conn(:post, @mount, body) |> put_req_header("content-type", content_type)
  end

  @doc "Everything a client can compare: status, every response header (sorted) and body."
  @spec fp(Plug.Conn.t()) :: %{
          status: integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }
  def fp(conn) do
    %{status: conn.status, headers: Enum.sort(conn.resp_headers), body: conn.resp_body}
  end

  # ── observation ─────────────────────────────────────────────────────────

  @doc false
  def handle_query(_event, _measurements, meta, {pid, ref}) do
    if self() == pid, do: send(pid, {:q, ref, meta})
    :ok
  end

  @doc false
  def handle_outcome(_event, measurements, meta, {pid, ref}) do
    send(pid, {:o, ref, {measurements, meta}})
    :ok
  end

  @doc "Runs `fun`; returns `{result, queries}` (telemetry meta of this process's Repo queries)."
  @spec capture_queries((-> result)) :: {result, [map()]} when result: term()
  def capture_queries(fun) do
    ref = make_ref()
    me = self()
    id = {__MODULE__, :q, ref}

    :telemetry.attach(id, [:letflow, :repo, :query], &__MODULE__.handle_query/4, {me, ref})

    try do
      result = fun.()
      {result, drain({:q, ref}, [])}
    after
      :telemetry.detach(id)
    end
  end

  @doc "Runs `fun`; returns `{result, [{measurements, metadata}]}` of every outcome event."
  @spec capture_outcomes((-> result)) :: {result, [{map(), map()}]} when result: term()
  def capture_outcomes(fun) do
    ref = make_ref()
    me = self()
    id = {__MODULE__, :o, ref}

    :telemetry.attach(id, @outcome, &__MODULE__.handle_outcome/4, {me, ref})

    try do
      result = fun.()
      {result, drain({:o, ref}, [])}
    after
      :telemetry.detach(id)
    end
  end

  @doc """
  Runs `fun` counting calls to `Letflow.LoginDiscovery.Dispatch.submit/3` made by
  THIS process (call-trace; the router runs in the test process).
  """
  @spec capture_submissions((-> result)) :: {result, non_neg_integer()} when result: term()
  def capture_submissions(fun) do
    me = self()
    # a process that is its OWN tracer emits no trace messages: use a collector process
    collector = spawn_link(fn -> collect_traces(0) end)
    {:module, _} = Code.ensure_loaded(Letflow.LoginDiscovery.Dispatch)
    1 = :erlang.trace_pattern({Letflow.LoginDiscovery.Dispatch, :submit, 3}, true, [:local])
    1 = :erlang.trace(me, true, [:call, {:tracer, collector}])

    try do
      result = fun.()
      :erlang.trace(me, false, [:call])
      # trace messages are asynchronous: wait for the VM's delivery marker before counting
      ref = :erlang.trace_delivered(me)

      receive do
        {:trace_delivered, ^me, ^ref} -> :ok
      end

      send(collector, {:count, me, ref})

      receive do
        {^ref, n} -> {result, n}
      end
    after
      :erlang.trace(me, false, [:call])
      :erlang.trace_pattern({Letflow.LoginDiscovery.Dispatch, :submit, 3}, false, [:local])
      Process.unlink(collector)
      Process.exit(collector, :kill)
    end
  end

  defp collect_traces(n) do
    receive do
      {:trace, _pid, :call, {Letflow.LoginDiscovery.Dispatch, :submit, _args}} ->
        collect_traces(n + 1)

      {:count, from, ref} ->
        send(from, {ref, n})
        collect_traces(n)
    end
  end

  defp drain(tag, acc) do
    {name, ref} = tag

    receive do
      {^name, ^ref, item} -> drain(tag, [item | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Waits (bounded) until the notifier TaskSupervisor has no running child."
  @spec await_idle() :: :ok
  def await_idle do
    await_idle(60)
  end

  defp await_idle(0), do: ExUnit.Assertions.flunk("notifier tasks did not finish within 6 s")

  defp await_idle(n) do
    case Task.Supervisor.children(@supervisor) do
      [] ->
        :ok

      _busy ->
        Process.sleep(100)
        await_idle(n - 1)
    end
  end

  @doc "Messages `{:deliver_tenant_list, recipient, tenants}` currently in the mailbox."
  @spec deliveries() :: [{String.t(), [map()]}]
  def deliveries, do: collect_deliveries([])

  defp collect_deliveries(acc) do
    receive do
      {:deliver_tenant_list, recipient, tenants} ->
        collect_deliveries([{recipient, tenants} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Raises the Logger level to `:debug` for the test (restored in `on_exit/1`)."
  @spec debug_logging!() :: :ok
  def debug_logging! do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
  end
end
