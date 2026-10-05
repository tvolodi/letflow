defmodule Letflow.LoginDiscovery.Notifier.Smtp.Transport do
  @moduledoc """
  The ONLY module that names the mail library (`:gen_smtp`; decision
  `docs/migration/decisions/0045-mail-library-choice.md`, REQ-441 design s2.1).

  Contract (design M2): the send is `:gen_smtp_client.send_blocking/2`, a
  BLOCKING call that runs in the CALLING process (the inner `Dispatch` task);
  no worker is spawned and nothing is linked, so a `:brutal_kill` of that task
  closes the socket with it and no crash report can print the options (the
  password). See "Verified against deps/gen_smtp 1.3.0 source" in decision 0045.

  Fixed security options (not configurable from the environment):

    * `retries: 0` -- one attempt (library: `fetch_next_host/5`), plus
      `no_mx_lookups: true` so there is exactly one host;
    * STARTTLS mode uses `tls: :always`: a server that does not offer STARTTLS,
      or a failed or unverified upgrade, is an error, never a plaintext fallback;
    * peer verification (`verify_peer`, OS CA store, SNI and hostname match,
      TLS 1.2/1.3 only) for both STARTTLS and implicit TLS;
    * `auth: :always`: the credentials are only ever sent after TLS (or on the
      loopback-only `tls: :none` mode);
    * the EHLO identity and the `Message-ID` domain are the sender's domain;
    * the message is built in this module (see `encode/5`), not by mimemail.

  `credentials` is a function argument for the duration of one call (INV-4); it
  is never returned, stored or logged, and no library return is ever inspected
  or logged: every failure collapses to `{:error, :failed}`.
  """

  alias Letflow.LoginDiscovery.Notifier.Smtp.Config
  alias Letflow.LoginDiscovery.Notifier.Smtp.Message

  # Compile-time gate (design s3.4): the test CA override is compiled in ONLY
  # when config/test.exs sets this flag. In every other build the branch below
  # does not exist and a `tls_cacerts` app-env value is ignored.
  @allow_test_cacerts Application.compile_env(
                        :letflow,
                        [Letflow.LoginDiscovery.Notifier.Smtp, :allow_test_cacerts],
                        false
                      )

  @type connection :: %{
          host: String.t(),
          port: 1..65535,
          tls: Config.tls_mode(),
          socket_timeout_ms: pos_integer()
        }

  @spec send_message(
          Message.composed(),
          connection(),
          {String.t(), String.t()},
          keyword()
        ) :: :ok | {:error, :failed}
  def send_message(
        %{from: from, to: to, subject: subject, body: body},
        %{host: host, port: port, tls: tls, socket_timeout_ms: socket_timeout_ms},
        {username, password},
        _opts
      ) do
    domain = sender_domain(from)
    data = encode(from, to, subject, body, domain)

    options = [
      relay: String.to_charlist(host),
      port: port,
      no_mx_lookups: true,
      ssl: tls == :tls,
      tls: if(tls == :starttls, do: :always, else: :never),
      tls_options: tls_options(host),
      sockopts: if(tls == :tls, do: tls_options(host), else: []),
      auth: :always,
      username: username,
      password: password,
      hostname: String.to_charlist(domain),
      retries: 0,
      timeout: socket_timeout_ms,
      on_transaction_error: :quit,
      protocol: :smtp
    ]

    case :gen_smtp_client.send_blocking({"<#{from}>", ["<#{to}>"], data}, options) do
      receipt when is_binary(receipt) -> :ok
      _failure -> {:error, :failed}
    end
  rescue
    _exception -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  defp sender_domain(from) do
    [_local, domain] = :binary.split(from, "@")
    domain
  end

  # The RFC 5322 message is built here, not with `:mimemail.encode/1`: mimemail logs
  # the complete header list (including `To`, the recipient) at DEBUG on every encode
  # (deps/gen_smtp/src/mimemail.erl, get_header_value/3, domain [gen_smtp]), which
  # would put the address in any debug log. Every header is fixed ASCII or a value
  # that already passed the address allow-list; a non-ASCII body travels base64-encoded,
  # so no body or tenant text can become a header or a bare dot line. An all-ASCII body
  # (the usual case) is sent as 7bit so the raw DATA stays readable; any non-ASCII
  # (UTF-8 display name) body is base64-encoded.
  defp encode(from, to, subject, body, domain) do
    if Enum.any?([from, to, subject], &unsafe_header?/1), do: throw(:unsafe_header)

    message_id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    crlf_body = String.replace(body, "\n", "\r\n")

    {transfer_encoding, encoded_body} =
      if ascii?(crlf_body) do
        {"7bit", crlf_body}
      else
        {"base64",
         crlf_body
         |> Base.encode64()
         |> then(&Regex.scan(~r/.{1,76}/, &1))
         |> Enum.map_join("\r\n", &hd/1)}
      end

    headers = [
      "Date: " <> rfc5322_date(),
      "From: " <> from,
      "To: " <> to,
      "Subject: " <> subject,
      "Message-ID: <" <> message_id <> "@" <> domain <> ">",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: " <> transfer_encoding
    ]

    Enum.join(headers, "\r\n") <> "\r\n\r\n" <> encoded_body
  end

  defp ascii?(binary), do: Enum.all?(:binary.bin_to_list(binary), &(&1 < 128))

  defp unsafe_header?(value), do: String.contains?(value, ["\r", "\n", <<0>>])

  defp rfc5322_date do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    weekday =
      Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), :calendar.day_of_the_week(year, month, day) - 1)

    month_name = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), month - 1)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")

    "#{weekday}, #{pad.(day)} #{month_name} #{year} #{pad.(hour)}:#{pad.(minute)}:#{pad.(second)} +0000"
  end

  defp tls_options(host) do
    [
      verify: :verify_peer,
      cacerts: cacerts(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]
  end

  if @allow_test_cacerts do
    defp cacerts do
      case Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier.Smtp, [])[:tls_cacerts] do
        [_ | _] = ders -> ders
        _none -> :public_key.cacerts_get()
      end
    end
  else
    defp cacerts, do: :public_key.cacerts_get()
  end
end
