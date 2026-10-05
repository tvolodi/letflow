defmodule Letflow.Test.SmtpHelpers do
  @moduledoc """
  REQ-441 shared test helpers for the SMTP adapter suites (spec `test/specs/REQ-441.md`).
  Test-only; never referenced from `lib/`.

  `configure_smtp!/2` points the adapter at an in-process `Letflow.Test.SmtpSink`:
  the non-secret `Smtp` app env, the `Notifier` env (adapter `Smtp`, `timeout_ms` set
  EXPLICITLY because `config/test.exs` sets 1000, design s6.1 G3), and the two credential
  variables in the OS environment, all restored by `on_exit/1`.

  The credential markers are built once, at compile time, from random bytes and are never
  written as `NAME=value` text anywhere (the AC6 tracked-tree guard scans for that).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Letflow.Test.SmtpSink

  @smtp Letflow.LoginDiscovery.Notifier.Smtp
  @notifier Letflow.LoginDiscovery.Notifier
  @user_var "LETFLOW_SMTP_USERNAME"
  @pass_var "LETFLOW_SMTP_PASSWORD"
  @user "fake-user-" <> Base.encode16(:crypto.strong_rand_bytes(4))
  @pass "fake-pass-" <> Base.encode16(:crypto.strong_rand_bytes(6))
  @sender "noreply@mail.example.org"
  @base_url "https://app.example.org"
  @event [:letflow, :login_discovery, :notifier]

  def user_var, do: @user_var
  def pass_var, do: @pass_var
  def user, do: @user
  def pass, do: @pass
  def sender, do: @sender
  def base_url, do: @base_url
  def event_name, do: @event
  def smtp_module, do: @smtp

  @doc "Starts a sink for `script`; stopped in `on_exit/1`."
  @spec start_sink!(SmtpSink.script()) :: map()
  def start_sink!(script) do
    {:ok, sink} = SmtpSink.start(script)
    on_exit(fn -> SmtpSink.stop(sink) end)
    sink
  end

  @doc """
  Selects the `Smtp` adapter against `sink`. Options: `:host` ("127.0.0.1"), `:tls`
  (`:none`), `:timeout_ms` (10_000), `:socket_timeout_ms` (2_000), `:max_concurrent`
  (100), `:tls_cacerts` (a DER list, only for the TLS cases).
  """
  @spec configure_smtp!(map(), keyword()) :: :ok
  def configure_smtp!(sink, opts) do
    smtp_env =
      [
        host: Keyword.get(opts, :host, "127.0.0.1"),
        port: sink.port,
        tls: Keyword.get(opts, :tls, :none),
        from: @sender,
        base_url: @base_url,
        socket_timeout_ms: Keyword.get(opts, :socket_timeout_ms, 2_000)
      ] ++ Keyword.take(opts, [:tls_cacerts])

    put_app_env!(@smtp, smtp_env)

    put_app_env!(@notifier,
      adapter: @smtp,
      timeout_ms: Keyword.get(opts, :timeout_ms, 10_000),
      max_concurrent: Keyword.get(opts, :max_concurrent, 100)
    )

    put_os_env!(@user_var, @user)
    put_os_env!(@pass_var, @pass)
    :ok
  end

  @doc "Merges `values` over the application env of `namespace`; restored in `on_exit/1`."
  @spec put_app_env!(module(), keyword()) :: :ok
  def put_app_env!(namespace, values) do
    original = Application.fetch_env(:letflow, namespace)

    on_exit(fn ->
      case original do
        {:ok, env} -> Application.put_env(:letflow, namespace, env)
        :error -> Application.delete_env(:letflow, namespace)
      end
    end)

    base =
      case original do
        {:ok, env} -> env
        :error -> []
      end

    Application.put_env(:letflow, namespace, Keyword.merge(base, values))
  end

  @doc "Deletes the application env of `namespace`; restored in `on_exit/1`."
  @spec delete_app_env!(module()) :: :ok
  def delete_app_env!(namespace) do
    original = Application.fetch_env(:letflow, namespace)

    on_exit(fn ->
      case original do
        {:ok, env} -> Application.put_env(:letflow, namespace, env)
        :error -> :ok
      end
    end)

    Application.delete_env(:letflow, namespace)
  end

  @doc "Sets an OS environment variable; restored in `on_exit/1`."
  @spec put_os_env!(String.t(), String.t()) :: :ok
  def put_os_env!(name, value) do
    original = System.get_env(name)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(name)
        value -> System.put_env(name, value)
      end
    end)

    System.put_env(name, value)
  end

  @doc "Deletes an OS environment variable; restored in `on_exit/1`."
  @spec delete_os_env!(String.t()) :: :ok
  def delete_os_env!(name) do
    original = System.get_env(name)

    on_exit(fn ->
      case original do
        nil -> :ok
        value -> System.put_env(name, value)
      end
    end)

    System.delete_env(name)
  end

  @doc "Two active tenants, in the shape `Dispatch.submit/3` receives from the lookup."
  @spec tenants() :: [map()]
  def tenants do
    [
      %{slug: "acme-co", display_name: "Acme Corp", disclose: true},
      %{slug: "globex", display_name: "Globex Ltd", disclose: true}
    ]
  end

  @doc "Submits the multi-tenant lookup result for `recipient` exactly as the router does."
  @spec submit_multi(String.t(), [map()]) :: :ok
  def submit_multi(recipient, tenants) do
    Letflow.LoginDiscovery.Dispatch.submit(recipient, :redirect_single, {:ok, tenants})
  end

  @doc """
  Attaches a handler on the notifier event that forwards every event to the calling
  process as `{ref, :notifier, measurements, metadata}`; detached in `on_exit/1`.
  """
  @spec attach_notifier!() :: reference()
  def attach_notifier! do
    ref = make_ref()
    id = {__MODULE__, ref}
    :telemetry.attach(id, @event, &__MODULE__.forward/4, {self(), ref})
    on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  @doc false
  def forward(_event, measurements, metadata, {pid, ref}) do
    send(pid, {ref, :notifier, measurements, metadata})
    :ok
  end

  @doc "Waits (bounded) for the next notifier event; `:timeout` if none arrives."
  @spec next_event(reference(), non_neg_integer()) :: {map(), map()} | :timeout
  def next_event(ref, wait_ms) do
    receive do
      {^ref, :notifier, measurements, metadata} -> {measurements, metadata}
    after
      wait_ms -> :timeout
    end
  end

  @doc "Every notifier event currently in the mailbox, oldest first."
  @spec drain_events(reference()) :: [{map(), map()}]
  def drain_events(ref) do
    case next_event(ref, 0) do
      :timeout -> []
      event -> [event | drain_events(ref)]
    end
  end

  @doc "Polls `fun` until it is truthy (bounded, 100 ms steps); returns the last result."
  @spec wait_until((-> term())) :: boolean()
  def wait_until(fun), do: wait_until(fun, 100)

  @spec wait_until((-> term()), non_neg_integer()) :: boolean()
  def wait_until(fun, attempts) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && wait_until(fun, attempts - 1)
    end
  end
end
