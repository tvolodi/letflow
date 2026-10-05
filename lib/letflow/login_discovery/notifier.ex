defmodule Letflow.LoginDiscovery.Notifier do
  @moduledoc """
  Port for delivering the tenant list to an address that asked for it (REQ-437;
  design `req434-email-first-login-directory.md` s13).

  The adapter is selected by `config :letflow, Letflow.LoginDiscovery.Notifier,
  adapter: <module>` (default `Letflow.LoginDiscovery.Notifier.Noop`; the test
  config sets the test double). The real mail adapter is not built here
  (REQ-441).

  `recipient_email` is the normalised address the caller typed in THIS request,
  never a stored value. An adapter must never log or raise with the recipient,
  a slug or a display name in any message (INV-4); the caller isolates failures
  (INV-8), so an adapter may return `{:error, term}` or raise freely.
  """

  @callback deliver_tenant_list(
              recipient_email :: String.t(),
              tenants :: [Letflow.LoginDirectory.tenant_ref(), ...]
            ) :: :ok | {:error, term()}
end
