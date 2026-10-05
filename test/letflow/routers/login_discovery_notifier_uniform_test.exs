defmodule Letflow.Routers.LoginDiscoveryNotifierUniformTest do
  @moduledoc """
  REQ-441 AC3 (spec `test/specs/REQ-441.md`): UNIFORM RESPONSE WHATEVER THE DELIVERY
  RESULT, through the real `Letflow.Router` -> `Letflow.Routers.LoginDiscovery` chain.

  For the same multi-tenant address, status, every response header and the body are
  compared directly (`==` on `H.fp/1`) against a baseline taken with the Noop adapter,
  for: the test double succeeding, returning `{:error, _}`, raising, exiting, sleeping
  past the hard timeout; and the REAL `Smtp` adapter against the in-process sink
  accepting, refusing the recipient, refusing the connection, failing TLS (STARTTLS and
  implicit), dropping after the greeting and hanging. The request process must stay
  alive. Each case waits for the notifier event (not a sleep) before it ends, and
  asserts the event outcome so a case cannot pass vacuously (the adapter really ran and
  really failed).

  `async: false` (global limiter table, application env, the notifier supervisor, the
  sink).
  """

  use Letflow.DataCase, async: false

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.LoginDiscovery.Notifier.Noop
  alias Letflow.Test.LoginDiscoveryHelpers, as: H
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.Test.SmtpSink

  @notifier Letflow.LoginDiscovery.Notifier
  @neutral ~s({"result":"accepted"})
  @wait 15_000

  setup_all do
    {:ok, world: H.provision_world!([:a, :b])}
  end

  setup %{world: w} do
    H.setup_limiter!([])
    H.put_mode!(:redirect_single)
    H.put_enabled!(true)
    H.put_env!(@notifier, adapter: Noop, timeout_ms: 1_000, max_concurrent: 100)
    Double.reset()
    Double.set_owner(self())
    on_exit(&Double.reset/0)
    H.debug_logging!()
    H.await_idle()
    {:ok, w: w, events: S.attach_notifier!()}
  end

  # An address held by BOTH tenants: neutral 202, one delivery of a list of two.
  defp multi(w) do
    email = H.email()
    H.add_entry!(w.a, email)
    H.add_entry!(w.b, email)
    email
  end

  # The baseline: the same multi-tenant POST under the Noop adapter.
  defp baseline(w, events) do
    conn = H.post_email(multi(w))
    assert {%{count: 1}, %{outcome: :skipped}} = S.next_event(events, @wait)
    H.await_idle()
    fp = H.fp(conn)
    assert fp.status == 202 and fp.body == @neutral
    fp
  end

  # Runs the case POST and asserts byte-identity with the baseline, request process alive.
  defp assert_uniform(w, events, baseline, expected_outcome) do
    conn = H.post_email(multi(w))
    assert Process.alive?(self())
    assert H.fp(conn) == baseline
    assert conn.status == baseline.status
    assert Enum.sort(conn.resp_headers) == baseline.headers
    assert conn.resp_body == baseline.body

    assert {%{count: 1}, %{outcome: ^expected_outcome}} = S.next_event(events, @wait),
           "the delivery attempt did not end with #{expected_outcome}"

    assert Process.alive?(self())
    conn
  end

  describe "the notifier test double (every adapter result)" do
    for {label, behaviour, outcome} <- [
          {:ok, :ok, :delivered},
          {:error_tuple, :error, :failed},
          {:raise, :raise, :failed},
          {:exit, :exit, :failed},
          {:sleep_past_timeout, {:sleep, 5_000}, :failed}
        ] do
      test "adapter #{label}: response bytes equal the baseline", %{w: w, events: events} do
        baseline = baseline(w, events)

        H.put_env!(@notifier, adapter: Double, timeout_ms: 300, max_concurrent: 100)
        Double.set_behaviour(unquote(Macro.escape(behaviour)))

        assert_uniform(w, events, baseline, unquote(outcome))
        H.await_idle()
        # the adapter really was invoked for the case under test
        assert [{_recipient, [_, _]}] = H.deliveries()
      end
    end
  end

  describe "the real Smtp adapter against the in-process sink" do
    for {label, script, tls, opts, outcome} <- [
          {:accepted, :accept, :none, [], :delivered},
          {:recipient_refused, {:refuse_rcpt, "REFUSEDMARKER"}, :none, [], :failed},
          {:temporary_failure, {:tempfail_rcpt, "LATERMARKER"}, :none, [], :failed},
          {:connection_refused, :refuse_connection, :none, [], :failed},
          {:dropped_after_greeting, :drop_after_greeting, :none, [], :failed},
          {:starttls_untrusted, {:starttls, :untrusted}, :starttls, [host: "localhost"], :failed},
          {:starttls_not_offered, :no_starttls_offered, :starttls, [host: "localhost"], :failed},
          {:implicit_tls_untrusted, {:implicit_tls, :untrusted}, :tls, [host: "localhost"],
           :failed},
          {:hang_until_hard_timeout, :hang, :none, [timeout_ms: 1_500, socket_timeout_ms: 500],
           :failed}
        ] do
      test "sink #{label}: response bytes equal the baseline", %{w: w, events: events} do
        baseline = baseline(w, events)

        sink = S.start_sink!(unquote(Macro.escape(script)))
        opts = unquote(Macro.escape(opts))

        opts =
          case sink.ca_der do
            nil -> opts
            ca -> opts ++ [tls_cacerts: [ca]]
          end

        S.configure_smtp!(sink, [tls: unquote(tls)] ++ opts)

        assert_uniform(w, events, baseline, unquote(outcome))
        assert S.wait_until(fn -> SmtpSink.open_connections(sink) == 0 end)

        case unquote(outcome) do
          :delivered -> assert [_one] = SmtpSink.messages(sink)
          :failed -> assert SmtpSink.messages(sink) == []
        end
      end
    end

    test "the response does not wait for the delivery: it is built while the hung task still runs",
         %{w: w, events: events} do
      baseline = baseline(w, events)
      sink = S.start_sink!(:hang)
      S.configure_smtp!(sink, timeout_ms: 1_500, socket_timeout_ms: 500)

      conn = H.post_email(multi(w))

      assert H.fp(conn) == baseline
      assert Task.Supervisor.children(Letflow.LoginDiscovery.TaskSupervisor) != []
      assert {%{count: 1}, %{outcome: :failed}} = S.next_event(events, @wait)
    end

    test "a delivered case is exactly one sink conversation to the typed address",
         %{w: w, events: events} do
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])
      email = multi(w)

      assert H.post_email(email).status == 202
      assert {_, %{outcome: :delivered}} = S.next_event(events, @wait)

      assert [%{rcpts: [^email]}] = SmtpSink.messages(sink)
      assert SmtpSink.connections(sink) == 1
    end
  end
end
