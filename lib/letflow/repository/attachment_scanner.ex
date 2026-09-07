defmodule Letflow.Repository.AttachmentScanner do
  @moduledoc """
  Behaviour for a pluggable content-scanning/antivirus adapter, consulted
  synchronously by `Letflow.Repository.Attachments.upload/2` (ISS-0399, see
  `lib/letflow/design/iss0399-attachment-content-scanning.md` §2/§3).

  Resolved via
  `Application.get_env(:letflow, :attachment_scanner, Letflow.Repository.AttachmentScanner.SignatureHeuristic)`
  -- the same safe-default resolution shape
  `lib/letflow/engine/lua/platform.ex:774`'s `lua_platform_service_caller` uses
  (design §3.1), **not** `Letflow.Oidc.TokenVerifier`'s fail-fast
  `fetch_env!`/`Keyword.fetch!` shape -- deliberately, per the design's own
  stated reasoning (§3.1): the default adapter here (`SignatureHeuristic`) is a
  real, complete, permanently-correct scanning policy on its own, not a
  placeholder that merely avoids a crash, so no environment is ever forced to
  configure this key.

  A conforming adapter must never raise -- any failure (network error,
  timeout, unexpected response shape from a future external scanner) must be
  caught and returned as `{:error, reason}` (INV-8, design §6). The default
  adapter (`SignatureHeuristic`) performs no I/O and can never produce that
  branch itself; the branch exists in this contract for a future adapter that
  does (design §3.2/§3.3).
  """

  @typedoc "A short, non-sensitive description of why content was flagged -- never raw bytes (INV-4)."
  @type verdict :: String.t()

  @callback scan(raw_bytes :: binary(), content_type :: String.t()) ::
              {:ok, :clean}
              | {:ok, :infected, verdict()}
              | {:error, reason :: term()}
end
