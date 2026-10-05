defmodule Letflow.LoginDiscovery.Dispatch do
  @moduledoc """
  Off-request-path notifier dispatch of the login-discovery endpoint (REQ-437;
  design `req434-email-first-login-directory.md` s13).

  `submit/3` is called exactly once per request, matched or not (so request
  timing never depends on a match or on mail latency), and always returns `:ok`
  without awaiting anything. It hands one zero-arity CLOSURE to
  `Task.Supervisor.start_child/2` on `Letflow.LoginDiscovery.TaskSupervisor`
  (C-4: never an MFA form, so no recipient, tenant list or key can appear in an
  `Args:` line of a crash report). A refusal of `start_child` (the supervisor's
  `max_children` cap, `max_concurrent`) or an exit is dropped silently.

  Inside the task: `LoginDiscovery.delivery/2` decides whether anything is to be
  delivered; if so the per-address `:send` bucket is consumed first
  (`LoginDiscoveryRateLimit.consume_email_silent(key, :send)`; a refusal skips the
  send and emits no outcome event, the request already emitted its one); then the configured adapter runs in an inner supervised task under a
  hard timeout (`timeout_ms`, killed on expiry). A raise, exit, throw, error
  return or timeout is dropped with one FIXED log line carrying no email,
  tenant, slug or exception text (INV-4, INV-8); it never reaches the HTTP
  response.

  Config: `config :letflow, Letflow.LoginDiscovery.Notifier, adapter:,
  timeout_ms:, max_concurrent:`.
  """

  require Logger

  alias Letflow.LoginDirectory
  alias Letflow.LoginDiscovery
  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Limiter

  @supervisor Letflow.LoginDiscovery.TaskSupervisor
  @default_adapter Letflow.LoginDiscovery.Notifier.Noop
  @default_timeout_ms 5_000
  @default_max_concurrent 100

  @doc "Submits exactly one notifier task for this request; always `:ok`."
  @spec submit(String.t() | nil, LoginDiscovery.mode(), LoginDiscovery.result()) :: :ok
  def submit(recipient_email, mode, result) do
    adapter = adapter()
    timeout = timeout_ms()
    fun = fn -> run(recipient_email, mode, result, adapter, timeout) end

    try do
      _ = Task.Supervisor.start_child(@supervisor, fun)
      :ok
    catch
      _kind, _reason -> :ok
    end
  end

  @doc "The configured notifier adapter module (default the Noop adapter)."
  @spec adapter() :: module()
  def adapter do
    case config() |> Keyword.get(:adapter) do
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _other -> @default_adapter
    end
  end

  @doc "Hard timeout of one delivery attempt, in milliseconds."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: positive(Keyword.get(config(), :timeout_ms), @default_timeout_ms)

  @doc """
  Cap on concurrent deliveries. Each delivery holds TWO supervisor slots (the
  outer `start_child` closure plus the inner `async_nolink` adapter task on the
  same `Task.Supervisor`), so the supervisor's `max_children` is
  `2 * max_concurrent()`.
  """
  @spec max_concurrent() :: pos_integer()
  def max_concurrent,
    do: positive(Keyword.get(config(), :max_concurrent), @default_max_concurrent)

  defp config, do: Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier, [])

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_other, default), do: default

  # Runs inside the supervised task. Everything is caught: nothing about the
  # recipient or the tenants may reach a crash report or a log line.
  defp run(recipient, mode, result, adapter, timeout) do
    with true <- is_binary(recipient),
         {:deliver, tenants} <- LoginDiscovery.delivery(mode, result),
         {:ok, [key | _previous]} <- LoginDirectory.email_keys(recipient),
         :ok <- Limiter.consume_email_silent(key, :send) do
      deliver(adapter, recipient, tenants, timeout)
    else
      _skip -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp deliver(adapter, recipient, tenants, timeout) do
    task =
      Task.Supervisor.async_nolink(@supervisor, fn ->
        try do
          adapter.deliver_tenant_list(recipient, tenants)
        rescue
          _exception -> {:error, :adapter_failed}
        catch
          _kind, _reason -> {:error, :adapter_failed}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      _failed ->
        Logger.warning("login discovery: notifier delivery did not complete")
        :ok
    end
  end
end
