defmodule Letflow.Plugs.ContentType do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Content-Type enforcement — ports `src/api/middleware/content_type.zig`
  (119 lines). See `lib/letflow/design/req068-validation.md` §0.2 for the
  full decision table this ports verbatim, including the PUT-with-no-body
  → 400 (not 415) case.

  Reads the raw `content-type` request header (never `conn.body_params`,
  which does not exist yet — this plug is meant to run before any body
  parser). Not a `Plug.Parsers` replacement: install
  `Letflow.Plugs.SafeJsonParser` (REQ-068) after this plug in the pipeline,
  not instead of it.

  On reject: sends the problem document and `Plug.Conn.halt/1`s the conn, so
  no later plug (parsing, routing, dispatch) runs against a request this
  plug has already rejected.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Api.Response

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    method = conn.method
    content_type = conn |> get_req_header("content-type") |> List.first()
    has_body = has_body?(conn)

    case check(method, content_type, has_body) do
      :ok ->
        conn

      {:reject, :bad_request, detail} ->
        conn |> Response.bad_request(detail) |> halt()

      {:reject, :unsupported_media_type, detail} ->
        conn |> Response.unsupported_media_type(detail) |> halt()
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # Ports checkContentType/3 (content_type.zig:45-81) exactly, including the
  # PUT-with-no-body -> 400 branch a literal reading of "POST/PUT/PATCH
  # without Content-Type -> 415" would miss.
  @spec check(String.t(), String.t() | nil, boolean()) ::
          :ok | {:reject, :bad_request | :unsupported_media_type, String.t()}
  defp check(method, content_type, has_body) do
    is_post = method == "POST"
    is_put = method == "PUT"
    is_patch = method == "PATCH"

    cond do
      not (is_post or is_put or is_patch) ->
        :ok

      is_put and not has_body ->
        {:reject, :bad_request, "body is required for PUT"}

      true ->
        check_content_type(content_type)
    end
  end

  @spec check_content_type(String.t() | nil) ::
          :ok | {:reject, :unsupported_media_type, String.t()}
  defp check_content_type(nil) do
    {:reject, :unsupported_media_type, "Content-Type must be application/json"}
  end

  defp check_content_type(content_type) do
    if strip_params(content_type) == "application/json" do
      :ok
    else
      {:reject, :unsupported_media_type, "Content-Type must be application/json"}
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # Ports stripParams/1 (content_type.zig:114-119): strip everything from
  # the first ";" onward, trim trailing whitespace/tabs from what remains —
  # "application/json; charset=utf-8" -> "application/json".
  @spec strip_params(String.t()) :: String.t()
  defp strip_params(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim_trailing()
  end

  # A request "has a body" when Content-Length is present and non-zero, or
  # when Transfer-Encoding: chunked is set (a chunked request has no
  # Content-Length header at all but can still carry a body) — defensive:
  # this codebase has no route accepting chunked request bodies today, but
  # a false negative here (has_body? => false on a real chunked body) would
  # let an un-checked body through, so chunked defaults to "assume a body".
  @spec has_body?(Plug.Conn.t()) :: boolean()
  defp has_body?(conn) do
    case get_req_header(conn, "content-length") do
      [len] -> len != "0"
      [] -> "chunked" in get_req_header(conn, "transfer-encoding")
    end
  end
end
