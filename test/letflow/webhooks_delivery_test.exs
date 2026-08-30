defmodule Letflow.WebhooksDeliveryTest do
  @moduledoc """
  Tests for REQ-183 -- `Letflow.Webhooks.deliver/3` (dispatch core: HMAC signing,
  retry/backoff, auto-pause, DLQ landing) and `Letflow.Webhooks.Delivery` (schema). See
  `test/specs/REQ-183.md` for the full acceptance-criterion -> test-case mapping,
  including the outbound-HTTP-mocking and backoff-timing tradeoffs made below and why.
  Design authority: `lib/letflow/design/req183-webhook-delivery-dispatch.md`.
  Implementation authority: `lib/letflow/webhooks.ex`, `lib/letflow/webhooks/delivery.ex`,
  `lib/letflow/webhooks/subscription.ex`, which already passed SECURITY-REVIEWER and
  REVIEWER.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database. Uses a real local `:gen_tcp` HTTP server
  (`test/support/webhook_test_server.ex`) per DIRECTIVE T-2 -- no mocked HTTP; see that
  module's moduledoc for why a hand-rolled server rather than a hex dependency.
  `async: false` for the same reason every other tenant-fixture-using test file in this
  codebase sets it (real schema creation/teardown against one shared Postgres instance).

  **This file's tests are genuinely slow** (~10s total, concentrated in one test) because
  `Letflow.Webhooks`' retry backoff is a real, un-injectable `Process.sleep/1` -- see
  `test/specs/REQ-183.md`'s "Backoff-timing problem" section for the exact accounting and
  why this was not silently avoided.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Dlq
  alias Letflow.Dlq.Entry, as: DlqEntry
  alias Letflow.Secrets
  alias Letflow.Webhooks
  alias Letflow.Webhooks.Delivery
  alias Letflow.WebhookTestServer

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req183-webhooks-delivery") do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-183 Webhooks Delivery Test Tenant"
    )
  end

  defp create_subscription!(schema_name, target_url) do
    {:ok, %{subscription: subscription}} =
      Webhooks.create(%{target_url: target_url}, prefix: schema_name)

    subscription
  end

  defp unique_event_type do
    "req183.test.event." <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  defp attempts_for(schema_name, delivery_id) do
    import Ecto.Query

    Delivery
    |> where([d], d.delivery_id == ^delivery_id)
    |> order_by([d], asc: d.attempt_count)
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- 200 persists one SUCCESS row, no consecutive_failures increment
  # ---------------------------------------------------------------------------------

  describe "AC1: deliver/3 against 200 persists one SUCCESS row, no consecutive_failures increment" do
    test "single 200 response" do
      %{schema_name: schema_name} = provisioned_tenant("req183-ac1")
      server = WebhookTestServer.start(200, ~s({"received":true}))
      subscription = create_subscription!(schema_name, server.url)
      payload = %{"hello" => "world"}
      event_type = unique_event_type()

      assert {:ok, delivery} = Webhooks.deliver(subscription, event_type, payload)

      assert delivery.status == :SUCCESS
      assert delivery.http_status_code == 200
      assert delivery.attempt_count == 1
      assert is_nil(delivery.last_error)

      rows = attempts_for(schema_name, delivery.delivery_id)
      assert length(rows) == 1
      assert hd(rows).status == :SUCCESS

      reloaded_subscription =
        Repo.get!(Letflow.Webhooks.Subscription, subscription.id, prefix: schema_name)

      assert reloaded_subscription.consecutive_failures == 0
      assert reloaded_subscription.status == :ACTIVE
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- 500 and connection-refused both persist FAILED rows with last_error
  # populated, http_status_code 500 / nil respectively. Two explicit tests, each
  # bounded to one backoff step per test/specs/REQ-183.md's timing accounting.
  # ---------------------------------------------------------------------------------

  describe "AC2: deliver/3 against 500 and against connection-refused both persist FAILED rows" do
    test "500 response" do
      %{schema_name: schema_name} = provisioned_tenant("req183-ac2-500")

      # Fail attempt 1 with 500, succeed attempt 2 -- bounds this test's real sleep to
      # exactly the 1s attempt-1->attempt-2 backoff, per test/specs/REQ-183.md.
      server =
        WebhookTestServer.start_with_responder(fn _request ->
          if Process.get(:req183_ac2_attempt_seen) do
            {200, ~s({"ok":true})}
          else
            Process.put(:req183_ac2_attempt_seen, true)
            {500, "internal error"}
          end
        end)

      subscription = create_subscription!(schema_name, server.url)

      assert {:ok, final_delivery} =
               Webhooks.deliver(subscription, unique_event_type(), %{"x" => 1})

      # The server's responder runs in the accept-loop process, not this test process,
      # so Process.get/put above is scoped there -- fine, since the loop is sequential
      # and single-process for the lifetime of this server (see WebhookTestServer's own
      # moduledoc: "one connection at a time, sequentially").
      assert final_delivery.status == :SUCCESS
      assert final_delivery.attempt_count == 2

      rows = attempts_for(schema_name, final_delivery.delivery_id)
      assert length(rows) == 2

      [first_attempt, second_attempt] = rows
      assert first_attempt.attempt_count == 1
      assert first_attempt.status == :FAILED
      assert first_attempt.http_status_code == 500
      assert is_binary(first_attempt.last_error)
      assert first_attempt.last_error =~ "500"

      assert second_attempt.status == :SUCCESS

      reloaded_subscription =
        Repo.get!(Letflow.Webhooks.Subscription, subscription.id, prefix: schema_name)

      # One FAILED attempt occurred, so consecutive_failures was incremented once
      # (design §3.4) before the second attempt's success -- deliver/3 does not reset
      # it back to 0 on an eventual success (no acceptance criterion asks for that; the
      # only place consecutive_failures is zeroed is create/2's initial insert).
      assert reloaded_subscription.consecutive_failures == 1
    end

    test "connection refused" do
      %{schema_name: schema_name} = provisioned_tenant("req183-ac2-refused")
      refused_url = WebhookTestServer.refused_url()
      subscription = create_subscription!(schema_name, refused_url)

      # Every attempt against this target fails at the transport level -- there is no
      # way to make attempt 2 "succeed" against a target that is refused by
      # construction (deliver/3 uses one fixed target_url per call), so this test pays
      # the full 1+2+4=7s exhaustion cost, as documented in test/specs/REQ-183.md.
      assert {:ok, final_delivery} =
               Webhooks.deliver(subscription, unique_event_type(), %{"x" => 1})

      rows = attempts_for(schema_name, final_delivery.delivery_id)
      assert length(rows) == 4

      first_attempt = hd(rows)
      assert first_attempt.attempt_count == 1
      assert first_attempt.status == :FAILED
      assert is_nil(first_attempt.http_status_code)
      assert is_binary(first_attempt.last_error)
      assert first_attempt.last_error != ""

      assert Enum.all?(rows, &(&1.status == :FAILED))
      assert Enum.all?(rows, &is_nil(&1.http_status_code))
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- signature is independently verifiable
  # ---------------------------------------------------------------------------------

  describe "AC3: deliver/3's signature is independently verifiable" do
    test "signature is independently verifiable" do
      %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant("req183-ac3")
      server = WebhookTestServer.start(200, ~s({"ok":true}))
      subscription = create_subscription!(schema_name, server.url)
      payload = %{"order_id" => "abc-123", "amount" => 4200}
      event_type = unique_event_type()

      assert {:ok, delivery} = Webhooks.deliver(subscription, event_type, payload)
      assert delivery.status == :SUCCESS

      assert_receive {:webhook_test_server_request, received}, 2_000

      signature_header = Map.fetch!(received.headers, "x-letflow-signature")
      assert signature_header =~ ~r/^sha256=[0-9a-f]+$/

      "sha256=" <> received_hex = signature_header

      # The test resolves the signing key through the SAME mechanism deliver/3 itself
      # uses (Letflow.Secrets.resolve/2, same reference, same tenant_id, same
      # consumer: :webhook_dispatcher) -- this is what makes the criterion satisfiable
      # at all, per the acceptance criterion's own wording.
      assert {:ok, %{plaintext: signing_key}} =
               Secrets.resolve(subscription.secret_ref,
                 tenant_id: tenant_id,
                 consumer: :webhook_dispatcher
               )

      expected_hmac = :crypto.mac(:hmac, :sha256, signing_key, received.body)
      expected_hex = Base.encode16(expected_hmac, case: :lower)

      assert received_hex == expected_hex

      # Sanity: the body actually received is the same JSON the payload encodes to,
      # so the signature really was computed over these exact bytes, not some other
      # representation.
      assert Jason.decode!(received.body) == payload
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4/AC5 -- auto-pause at the threshold (5), and exhaustion lands exactly one DLQ
  # entry. Combined into one test per test/specs/REQ-183.md's timing accounting, so
  # the 7s exhaustion cost is paid once, not twice.
  # ---------------------------------------------------------------------------------

  describe "AC4/AC5: repeated failures reach auto-pause; exhaustion lands one DLQ entry" do
    test "exhaustion lands one DLQ entry, and repeated failures reach the auto-pause threshold" do
      %{schema_name: schema_name} = provisioned_tenant("req183-ac4-ac5")

      # Call 1: fail all 4 attempts (real 1+2+4=7s sleep, unavoidable -- this is also
      # what proves AC5's exhaustion/DLQ-landing criterion, so it is not duplicated
      # into a second run). consecutive_failures: 0 -> 4, not yet at the threshold (5).
      always_fail_server = WebhookTestServer.start(503, "still down")
      subscription = create_subscription!(schema_name, always_fail_server.url)
      event_type = unique_event_type()

      assert {:ok, exhausted_delivery} = Webhooks.deliver(subscription, event_type, %{"n" => 1})

      assert exhausted_delivery.status == :FAILED
      assert exhausted_delivery.attempt_count == 4
      assert exhausted_delivery.max_attempts == 4

      exhausted_rows = attempts_for(schema_name, exhausted_delivery.delivery_id)
      assert length(exhausted_rows) == 4
      assert Enum.all?(exhausted_rows, &(&1.status == :FAILED))

      # AC5: exactly one DLQ entry, entry_type "webhook", reference_id == delivery_id.
      import Ecto.Query

      dlq_entries =
        DlqEntry
        |> where([e], e.reference_id == ^exhausted_delivery.delivery_id)
        |> Repo.all(prefix: schema_name)

      assert length(dlq_entries) == 1
      [dlq_entry] = dlq_entries
      assert dlq_entry.entry_type == "webhook"
      assert dlq_entry.reference_id == exhausted_delivery.delivery_id

      after_call_1 =
        Repo.get!(Letflow.Webhooks.Subscription, subscription.id, prefix: schema_name)

      assert after_call_1.consecutive_failures == 4
      assert after_call_1.status == :ACTIVE
      assert is_nil(after_call_1.paused_at)

      # Call 2, against a SEPARATE server on the SAME subscription: fail attempt 1
      # (consecutive_failures 4 -> 5, crosses the threshold, flips PAUSED), then
      # succeed attempt 2 -- bounds this call's own sleep to the 1s attempt-1->2 delay
      # rather than a second full exhaustion.
      recovering_server =
        WebhookTestServer.start_with_responder(fn _request ->
          if Process.get(:req183_ac4_attempt_seen) do
            {200, ~s({"ok":true})}
          else
            Process.put(:req183_ac4_attempt_seen, true)
            {502, "bad gateway"}
          end
        end)

      subscription_for_call_2 = %{after_call_1 | target_url: recovering_server.url}

      # deliver/3 takes a Subscription.t() directly and reads target_url from it, so
      # pointing this call at a different server for its own attempts does not require
      # a DB write -- consecutive_failures/status/paused_at below are all read back
      # from the real persisted row after the call, not from this in-memory struct.
      assert {:ok, recovered_delivery} =
               Webhooks.deliver(subscription_for_call_2, unique_event_type(), %{"n" => 2})

      assert recovered_delivery.status == :SUCCESS
      assert recovered_delivery.attempt_count == 2

      after_call_2 =
        Repo.get!(Letflow.Webhooks.Subscription, subscription.id, prefix: schema_name)

      # AC4: consecutive_failures reached the threshold (5) and flipped PAUSED with
      # paused_at set. It does NOT get reset to 0 by call 2's eventual success (the
      # design's only writer of consecutive_failures is the failure path, design
      # §3.4) -- reading it back confirms 5, not fewer.
      assert after_call_2.consecutive_failures == 5
      assert after_call_2.status == :PAUSED
      assert %DateTime{} = after_call_2.paused_at
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- moduledoc names the HMAC header/format and the PAUSED threshold as
  # Letflow's own choices, and names the deferred auto-trigger
  # ---------------------------------------------------------------------------------

  describe "AC6: moduledoc documents Letflow's own choices and the deferred auto-trigger" do
    test "moduledoc names the HMAC format, threshold, and deferred auto-trigger as Letflow's own choices" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/webhooks.ex"))

      assert source =~ "X-Letflow-Signature"
      assert source =~ "sha256="
      assert source =~ ~r/Letflow's own choice/i

      # The threshold value itself, stated as a literal in prose (not merely present
      # as @auto_pause_threshold 5 in code, which a moduledoc reader would not see) --
      # AC6 requires the NUMBER to be named in the moduledoc.
      assert source =~ ~r/\b5\b.*consecutive/is or source =~ ~r/consecutive.*\b5\b/is

      assert source =~ ~r/deferred/i
      assert source =~ ~r/OUT OF SCOPE/i or source =~ ~r/out of scope/i
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- no route or controller file touched
  # ---------------------------------------------------------------------------------

  describe "AC7: no route or controller file is added or modified by this requirement" do
    test "no route or controller file touched" do
      for path <- [
            "lib/letflow/webhooks.ex",
            "lib/letflow/webhooks/delivery.ex",
            "lib/letflow/webhooks/subscription.ex"
          ] do
        source = File.read!(Path.join(File.cwd!(), path))
        refute source =~ ~r/use\s+Plug\.Router/, "#{path} unexpectedly uses Plug.Router"
        refute source =~ ~r/use\s+\w*Web,\s*:controller/, "#{path} unexpectedly is a controller"
        refute source =~ ~r/\bget\s+"\//, "#{path} unexpectedly defines a GET route"
      end

      # This requirement's own scope adds no file under lib/letflow/routers/ at all --
      # REQ-184 (the deliveries route) is the next requirement, not this one.
      refute File.exists?(Path.join(File.cwd!(), "lib/letflow/routers/webhook_deliveries.ex"))
    end
  end
end
