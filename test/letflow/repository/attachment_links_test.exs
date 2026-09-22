defmodule Letflow.Repository.AttachmentLinksTest do
  @moduledoc """
  Unit-level tests for REQ-386's `Letflow.Repository.AttachmentLinks.issue/3` and
  `verify/3`, written by TEST-DESIGNER at WF-02 Step 3. These exercise the module
  directly (no HTTP layer) -- `test/letflow/routers/req386_attachment_links_routes_test.exs`
  covers the two new routes built on top of it.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) because `issue/3`/`verify/3` both resolve a real
  `Letflow.Identity.Tenant` row (via `Letflow.Identity.get_tenant/1`) and read/write a
  real `secrets` row (via `Letflow.Secrets`). `async: false`, matching every other
  tenant-fixture-using test file in this codebase
  (`test/letflow/routers/req212_attachments_routes_test.exs`).

  Every expiry-dependent case uses `opts[:now]` injection (design §2.2 step 1 / AC2) --
  no `Process.sleep`, no reliance on wall-clock time, per
  `docs/guides/test_developer_guide.md` principle 3 and this run's own instruction.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repository.AttachmentLinks
  alias Letflow.TenantFixture

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-386 AttachmentLinks Unit Test Tenant"
    )
  end

  # A fixed base instant every clock-dependent test builds off of, so tests never
  # depend on real wall-clock time.
  @base_now ~U[2026-09-23 12:00:00Z]

  # ══════════════════════════════════════════════════════════════════════
  # AC1/AC2 -- valid round-trip: issue, then verify with the recovered
  # attachment id, before expiry
  # ══════════════════════════════════════════════════════════════════════

  describe "issue/3 + verify/3: valid round-trip" do
    test "a freshly issued token verifies successfully and recovers the same attachment_id" do
      tenant = provisioned_tenant("req386-roundtrip")
      attachment_id = Ecto.UUID.generate()

      assert {:ok, %{token: token, expires_at: expires_at}} =
               AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> @base_now end)

      assert is_binary(token)
      assert DateTime.compare(expires_at, @base_now) == :gt

      # Verified a moment later (still well within the 5-minute expiry) --
      # this proves the round trip actually works, not merely that issue/3
      # returns something.
      assert {:ok, ^attachment_id} =
               AttachmentLinks.verify(token, tenant.tenant_id,
                 now: fn -> DateTime.add(@base_now, 10, :second) end
               )
    end

    test "expires_at is exactly 300 seconds (the stated, bounded expiry) after the injected now" do
      tenant = provisioned_tenant("req386-expiry-bound")
      attachment_id = Ecto.UUID.generate()

      assert {:ok, %{expires_at: expires_at}} =
               AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> @base_now end)

      assert DateTime.diff(expires_at, @base_now, :second) == 300
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- expired via injected clock, no real sleep
  # ══════════════════════════════════════════════════════════════════════

  describe "verify/3: expired token (injected clock, no sleep)" do
    test "a token verified after its stated 300s expiry is refused" do
      tenant = provisioned_tenant("req386-expired")
      attachment_id = Ecto.UUID.generate()

      assert {:ok, %{token: token}} =
               AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> @base_now end)

      # One second past the 300s boundary -- deterministic, no Process.sleep.
      past_expiry = DateTime.add(@base_now, 301, :second)

      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify(token, tenant.tenant_id, now: fn -> past_expiry end)
    end

    test "a token verified at exactly its expires_at instant is already treated as expired (strict boundary)" do
      tenant = provisioned_tenant("req386-expired-boundary")
      attachment_id = Ecto.UUID.generate()

      assert {:ok, %{token: token, expires_at: expires_at}} =
               AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> @base_now end)

      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify(token, tenant.tenant_id, now: fn -> expires_at end)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 -- a fresh link for the same attachment_id after a prior one expired
  # succeeds
  # ══════════════════════════════════════════════════════════════════════

  describe "issue/3: a fresh issuance for the same attachment_id after a prior one expired" do
    test "succeeds independently -- issuance is stateless, no record of the prior (expired) token blocks it" do
      tenant = provisioned_tenant("req386-fresh-after-expired")
      attachment_id = Ecto.UUID.generate()

      assert {:ok, %{token: stale_token}} =
               AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> @base_now end)

      past_expiry = DateTime.add(@base_now, 301, :second)
      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify(stale_token, tenant.tenant_id, now: fn -> past_expiry end)

      # A fresh issuance for the SAME attachment_id, minted "later" (now =
      # past_expiry), verifies fine at a time shortly after ITS OWN issuance.
      assert {:ok, %{token: fresh_token}} =
               AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> past_expiry end)

      assert fresh_token != stale_token

      assert {:ok, ^attachment_id} =
               AttachmentLinks.verify(fresh_token, tenant.tenant_id,
                 now: fn -> DateTime.add(past_expiry, 5, :second) end
               )
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # verify/3: malformed token
  # ══════════════════════════════════════════════════════════════════════

  describe "verify/3: malformed token" do
    test "a token with no '.' separator is rejected" do
      tenant = provisioned_tenant("req386-malformed-noseparator")

      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify("not-a-real-token", tenant.tenant_id)
    end

    test "a token whose payload segment is not valid base64url is rejected" do
      tenant = provisioned_tenant("req386-malformed-badb64")

      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify("not!valid!base64.also-not-valid", tenant.tenant_id)
    end

    test "a token whose payload decodes but isn't valid JSON is rejected" do
      tenant = provisioned_tenant("req386-malformed-badjson")

      bogus_payload = Base.url_encode64("not json at all", padding: false)
      bogus_signature = Base.url_encode64("whatever", padding: false)

      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify(
                 "#{bogus_payload}.#{bogus_signature}",
                 tenant.tenant_id
               )
    end

    test "an empty string is rejected" do
      tenant = provisioned_tenant("req386-malformed-empty")

      assert {:error, :expired_or_invalid} = AttachmentLinks.verify("", tenant.tenant_id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # verify/3: wrong-tenant token (signed under a different tenant's key)
  # ══════════════════════════════════════════════════════════════════════

  describe "verify/3: wrong-tenant token" do
    test "a validly-issued token, presented under a different tenant, is rejected" do
      tenant_a = provisioned_tenant("req386-wrongtenant-a")
      tenant_b = provisioned_tenant("req386-wrongtenant-b")
      attachment_id = Ecto.UUID.generate()

      assert {:ok, %{token: token}} =
               AttachmentLinks.issue(attachment_id, tenant_a.tenant_id, now: fn -> @base_now end)

      # Same token, same recency (no expiry involved at all), only the
      # verifying tenant differs -- fails on signing-key mismatch, not
      # expiry.
      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify(token, tenant_b.tenant_id,
                 now: fn -> DateTime.add(@base_now, 1, :second) end
               )
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # verify/3: tampered payload/signature
  # ══════════════════════════════════════════════════════════════════════

  describe "verify/3: tampered token" do
    test "a token whose payload segment was swapped for a different, still-well-formed payload is rejected (signature no longer matches)" do
      tenant = provisioned_tenant("req386-tampered-payload")
      attachment_id = Ecto.UUID.generate()
      other_attachment_id = Ecto.UUID.generate()

      assert {:ok, %{token: token}} =
               AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> @base_now end)

      [_original_payload_b64, signature_b64] = String.split(token, ".", parts: 2)

      forged_payload =
        Jason.encode!(%{
          "attachment_id" => other_attachment_id,
          "expires_at" => DateTime.to_unix(DateTime.add(@base_now, 300, :second)),
          "key_id" => 1
        })

      forged_payload_b64 = Base.url_encode64(forged_payload, padding: false)
      tampered_token = "#{forged_payload_b64}.#{signature_b64}"

      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify(tampered_token, tenant.tenant_id,
                 now: fn -> DateTime.add(@base_now, 1, :second) end
               )
    end

    test "a token whose signature segment was altered by a single byte is rejected" do
      tenant = provisioned_tenant("req386-tampered-signature")
      attachment_id = Ecto.UUID.generate()

      assert {:ok, %{token: token}} =
               AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> @base_now end)

      [payload_b64, signature_b64] = String.split(token, ".", parts: 2)

      flipped_signature_b64 = flip_last_char(signature_b64)
      tampered_token = "#{payload_b64}.#{flipped_signature_b64}"

      assert {:error, :expired_or_invalid} =
               AttachmentLinks.verify(tampered_token, tenant.tenant_id,
                 now: fn -> DateTime.add(@base_now, 1, :second) end
               )
    end
  end

  defp flip_last_char(str) do
    {prefix, <<last>>} = String.split_at(str, byte_size(str) - 1)
    flipped = if last == ?A, do: ?B, else: ?A
    prefix <> <<flipped>>
  end
end
