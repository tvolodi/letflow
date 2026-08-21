defmodule Letflow.Plugs.SafeJsonParser do
  @moduledoc """
  `Plug.Parsers` wrapped so a malformed or oversized request body produces a
  typed `Letflow.Api.Response` problem document instead of an uncaught
  exception reaching the adapter as a bare-text 500 (INV-8). Not present in
  R-Co (Zig's manual body-reading loop has no analogous raise-on-failure
  behaviour to guard against) — see
  `lib/letflow/design/req068-validation.md` §0.3 for the full rationale.

  Install this in place of a bare `Plug.Parsers` plug declaration, after
  `Letflow.Plugs.ContentType` in the pipeline (that plug rejects a wrong
  Content-Type before this one would attempt to parse anything).
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Api.Response

  # 1 MiB — see design doc §4 for the justification and override mechanism
  # (pass `length: <n>` to `plug(Letflow.Plugs.SafeJsonParser, length: <n>)`).
  @max_body_bytes 1_000_000

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts) do
    [parsers: [:json], json_decoder: Jason, length: @max_body_bytes]
    |> Keyword.merge(opts)
    |> Plug.Parsers.init()
  end

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    e in Plug.Parsers.RequestTooLargeError ->
      conn |> Response.payload_too_large(Exception.message(e)) |> halt()

    _e in Plug.Parsers.ParseError ->
      conn |> Response.bad_request("request body is not valid JSON") |> halt()

    e in Plug.Parsers.UnsupportedMediaTypeError ->
      # Defensive: Letflow.Plugs.ContentType, running first in the pipeline,
      # should already make this unreachable — see design doc §0.3.
      conn |> Response.unsupported_media_type(Exception.message(e)) |> halt()
  end
end
