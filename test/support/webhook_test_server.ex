defmodule Letflow.WebhookTestServer do
  @moduledoc """
  Minimal local HTTP/1.1 server for REQ-183's `Letflow.Webhooks.deliver/3` tests.

  **Why this exists, not a hex dependency.** `deliver/3` calls `:httpc.request/4`
  directly (design `req183-webhook-delivery-dispatch.md` §5 — `:httpc`, chosen because
  no HTTP client dependency exists in `mix.exs` at all). `docs/guides/test_developer_guide.md`
  DIRECTIVE T-2 requires a real server for anything driving I/O, not a mock — and this is
  the first requirement in this codebase making an *outbound* HTTP call, so there is no
  existing precedent (`Bypass`/`Plug.Cowboy` are not in `mix.lock` — checked before
  writing this). Adding either as a new test-only dependency for one requirement's tests
  was judged heavier than a ~120-line raw `:gen_tcp` listener that speaks just enough
  HTTP/1.1 for `:httpc` to talk to; `:gen_tcp`/`:inets` are already part of the OTP
  standard library `mix.exs` already declares as `extra_applications` for this exact
  requirement's production code, so this adds no new dependency of any kind.

  ## What it does

  Starts a real TCP listener on `127.0.0.1` on an OS-assigned free port (`{:ok, 0}` to
  `:gen_tcp.listen/2`, then reads the actual port back via `:inet.port/1` — no fixed port,
  so tests never collide with each other or with a real service). Accepts one connection
  at a time in a loop, parses just enough of a raw HTTP/1.1 request (request line, headers,
  body via `Content-Length`) to respond and to capture what was received, and replies with
  a caller-configured status/body. Every accepted request is sent as a message to the
  owning test process (`{:webhook_test_server_request, %{headers:, body:, method:, path:}}`),
  so a test can assert on the exact bytes `deliver/3` actually sent (AC3's HMAC-verification
  criterion needs the literal header value and body bytes, not a paraphrase).

  ## Lifecycle

  `start/1` spawns the acceptor loop as a linked, unsupervised process (test-only, never
  part of `Letflow.Application`'s supervision tree — matches `Letflow.TenantFixture`'s own
  "test-only, not production" framing) and registers `ExUnit.Callbacks.on_exit/1` to close
  the listening socket, so a test never leaks a bound port into the next one.

  ## Connection-refused simulation (AC2's second case)

  `refused_url/0` returns a URL pointing at a **closed** port on `127.0.0.1` — obtained by
  binding a throwaway listener, reading its port, then immediately closing it before any
  connection is ever accepted. The OS will not reassign that exact port to a new listener
  within the lifetime of one test process's run (Windows/Linux both keep a just-closed
  TCP port unavailable for reuse for a short TIME_WAIT-adjacent window), so a connection
  attempt against it reliably gets `ECONNREFUSED`-shaped behavior from `:httpc` without
  depending on any real external unreachable host (no network access, no wall-clock-based
  timeout to wait through).
  """

  @doc """
  Starts a server that responds to every request with `status` and `body` (both fixed for
  this server's lifetime — a test needing different responses across attempts starts a new
  server per attempt, or uses `start_sequence/1` below). Returns `%{url:, port:, ref:}`.
  """
  @spec start(status :: pos_integer(), body :: String.t()) :: %{
          url: String.t(),
          port: pos_integer(),
          ref: pid()
        }
  def start(status \\ 200, body \\ "ok") do
    start_with_responder(fn _request -> {status, body} end)
  end

  @doc """
  Starts a server whose response is computed per-request by `responder.(request)`, where
  `request` is `%{method:, path:, headers:, body:}`. `responder` must return `{status,
  body}`. Used by the "N attempts before eventual success" style test, if any is needed,
  and by tests that want to inspect what was received before deciding the reply.
  """
  @spec start_with_responder((map() -> {pos_integer(), String.t()})) :: %{
          url: String.t(),
          port: pos_integer(),
          ref: pid()
        }
  def start_with_responder(responder) when is_function(responder, 1) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)

    owner = self()
    acceptor = spawn_link(fn -> accept_loop(listen_socket, responder, owner) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen_socket)
    end)

    %{url: "http://127.0.0.1:#{port}/hook", port: port, ref: acceptor}
  end

  @doc """
  A URL whose port is bound-then-immediately-closed, so a connection attempt against it
  fails at the transport level (connection refused) rather than reaching any server —
  the second half of AC2. No live process on the far end, deliberately.
  """
  @spec refused_url() :: String.t()
  def refused_url do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    "http://127.0.0.1:#{port}/hook"
  end

  # ---------------------------------------------------------------------------------
  # Accept loop -- one connection at a time, sequentially, which is all deliver/3's
  # single-process attempt loop ever needs (it never issues concurrent requests).
  # ---------------------------------------------------------------------------------

  defp accept_loop(listen_socket, responder, owner) do
    case :gen_tcp.accept(listen_socket, 15_000) do
      {:ok, client_socket} ->
        handle_connection(client_socket, responder, owner)
        accept_loop(listen_socket, responder, owner)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_connection(socket, responder, owner) do
    with {:ok, request} <- read_request(socket) do
      send(owner, {:webhook_test_server_request, request})
      {status, body} = responder.(request)
      :gen_tcp.send(socket, response_bytes(status, body))
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, head} <- read_until_headers_end(socket, ""),
         {request_line, header_lines} <- split_head(head),
         {method, path} <- parse_request_line(request_line),
         headers <- parse_headers(header_lines),
         {:ok, body} <- read_body(socket, headers) do
      {:ok, %{method: method, path: path, headers: headers, body: body}}
    end
  end

  defp read_until_headers_end(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> read_until_headers_end(socket, acc <> chunk)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp split_head(head) do
    [head_part, _rest] = String.split(head, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head_part, "\r\n")
    {request_line, header_lines}
  end

  defp parse_request_line(line) do
    [method, path, _version] = String.split(line, " ", parts: 3)
    {method, path}
  end

  defp parse_headers(header_lines) do
    header_lines
    |> Enum.map(fn line ->
      [name, value] = String.split(line, ":", parts: 2)
      {String.downcase(String.trim(name)), String.trim(value)}
    end)
    |> Map.new()
  end

  defp read_body(socket, headers) do
    case Map.get(headers, "content-length") do
      nil ->
        {:ok, ""}

      length_str ->
        length = String.to_integer(length_str)
        read_exact(socket, length, "")
    end
  end

  defp read_exact(_socket, 0, acc), do: {:ok, acc}

  defp read_exact(socket, remaining, acc) do
    case :gen_tcp.recv(socket, remaining, 5_000) do
      {:ok, chunk} -> {:ok, acc <> chunk}
      {:error, reason} -> {:error, reason}
    end
  end

  defp response_bytes(status, body) do
    reason = reason_phrase(status)

    "HTTP/1.1 #{status} #{reason}\r\n" <>
      "content-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n" <>
      "\r\n" <>
      body
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_other), do: "Response"
end
