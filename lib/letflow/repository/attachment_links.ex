defmodule Letflow.Repository.AttachmentLinks do
  @moduledoc """
  Context module for REQ-386's time-limited, signed attachment links:
  `issue/3` mints an opaque, self-contained HMAC-signed token naming an
  attachment id and a short expiry; `verify/3` validates one. See
  `lib/letflow/design/req386-attachment-signed-links.md` for the full design
  this module implements. Plain Ecto context module, no process, no
  `Repo.*` call of its own beyond what `Letflow.Secrets`/`Letflow.Identity`
  already perform internally -- same shape as
  `Letflow.Repository.Attachments`/`Letflow.Webhooks`.

  ## Why this is stateless (design §6)

  There is no "issued links" table. A token carries everything needed to
  verify it (the attachment id, its expiry, and which signing-key version it
  was signed with) plus an HMAC-SHA256 signature over that payload -- the
  same "self-contained bearer credential" shape `Letflow.Webhooks`' own
  outbound-delivery signing already establishes in this codebase
  (`:crypto.mac(:hmac, :sha256, signing_key, body)`), reused here rather than
  introducing a second, parallel signing scheme (`Phoenix.Token` is not used
  anywhere in this codebase).

  ## Tenant scoping (INV-1, design §7)

  The signing key is **per-tenant**, stored via the existing global
  `secrets` table (`Letflow.Secrets`, namespace `"attachments"`, name
  `"link_signing_key"`, purpose `:generic` -- already a legal
  `purpose`/`consumer` pair, no change to `Letflow.Secrets` needed).
  `verify/3` always resolves that key under the **requester's own**
  authenticated `tenant_id` -- never a tenant decoded from the token itself,
  which carries no tenant information at all. This is what makes a
  cross-tenant-presented token fail mechanically: the requester's own
  tenant's signing key (or lack of one) is never the key the token was
  actually signed with, so the recomputed HMAC cannot match.

  ## INV-4 -- secrets by reference only

  The signing-key plaintext is resolved via `Letflow.Secrets.resolve/2` (or
  generated locally by `issue/3` on first-ever issuance for a tenant) and
  used **only** as the immediate second argument to
  `:crypto.mac(:hmac, :sha256, ...)` -- never returned from either `issue/3`
  or `verify/3`, never logged. The opaque `token` string returned to a
  caller carries the payload and its signature, never the signing key
  itself.

  ## INV-5 / AC4 -- expired-or-invalid is one value, one response (design §2.3)

  `verify/3`'s six structurally distinct failure causes (malformed token,
  undecodable JSON, unknown tenant, unresolvable/wrong-tenant signing key,
  signature mismatch, expiry) all collapse to the single return value
  `{:error, :expired_or_invalid}`, via one `with`/`else` chain -- so a
  cross-tenant-presented token and a token naming an attachment id that was
  never issued at all are indistinguishable to every caller of this
  function, and therefore to whatever response the caller renders from it.
  """

  alias Letflow.Identity
  alias Letflow.Secrets

  @link_secret_namespace "attachments"
  @link_secret_name "link_signing_key"

  @typedoc "Injectable clock, for tests that need a fixed or near-past `now` instead of a real-time sleep (design §2.2 step 1 / AC2)."
  @type issue_opts :: [now: (-> DateTime.t())]

  @typedoc "Same injection point as `issue_opts()`, reused by `verify/3` so a test can present an already-expired token deterministically."
  @type verify_opts :: [now: (-> DateTime.t())]

  @doc """
  Mints a signed, time-limited token for `attachment_id`, scoped to
  `tenant_id`. The caller MUST already have proven `attachment_id` exists
  and is tenant/instance-scoped to the requester (via
  `Letflow.Routers.Instances`'s existing `fetch_scoped_attachment_metadata/3`)
  before calling this -- this function does not itself re-validate the
  attachment, it only mints a token for an id the caller has already proven
  access to.

  Expiry is a fixed 5 minutes (`@link_expiry_seconds`) from `opts[:now]`
  (defaults to `DateTime.utc_now/0`) -- short enough that a copy-pasted URL
  stops being useful within minutes, defense-in-depth on top of the standard
  `:AttachmentsRead`-gated pipeline the token-serving route still requires
  (design §2.1, flagged for REVIEWER as a judgment call, same precedent
  class as REQ-211's own `@max_upload_bytes`).

  Lazily creates the tenant's link-signing secret on first-ever issuance. A
  concurrent first-issuance race (two requests both finding no existing
  secret and both creating one) is possible and accepted as harmless: every
  token pins its own `key_id`, and `verify/3` always resolves that exact
  pinned version, never "the latest" (design §2.2 step 3).
  """
  @spec issue(attachment_id :: String.t(), tenant_id :: Ecto.UUID.t(), issue_opts()) ::
          {:ok, %{token: String.t(), expires_at: DateTime.t()}}
          | {:error, :invalid_tenant}
          | {:error, {:secret_write_failed, term()}}
  def issue(attachment_id, tenant_id, opts \\ [])
      when is_binary(attachment_id) and is_list(opts) do
    now = current_time(opts)
    expires_at = DateTime.add(now, link_expiry_seconds(), :second) |> DateTime.truncate(:second)

    with {:ok, tenant_slug} <- resolve_tenant_slug(tenant_id),
         {:ok, key_id, signing_key} <- get_or_create_signing_key(tenant_id, tenant_slug) do
      payload =
        Jason.encode!(%{
          "attachment_id" => attachment_id,
          "expires_at" => DateTime.to_unix(expires_at),
          "key_id" => key_id
        })

      signature = sign(signing_key, payload)

      token =
        Base.url_encode64(payload, padding: false) <>
          "." <> Base.url_encode64(signature, padding: false)

      {:ok, %{token: token, expires_at: expires_at}}
    end
  end

  @doc """
  Validates `token` against the signing key belonging to `tenant_id` (always
  the requester's own authenticated tenant -- never derived from the token,
  which carries no tenant information). Every failure -- malformed shape,
  undecodable payload, an unknown/wrong-tenant signing key, a signature
  mismatch, or a genuinely expired timestamp -- returns the same
  `{:error, :expired_or_invalid}` value; see this module's moduledoc for why
  that collapsing is what satisfies REQ-386's AC4.

  On success, returns the attachment id recovered from the token's
  (already-authenticated) payload.
  """
  @spec verify(token :: String.t(), tenant_id :: Ecto.UUID.t(), verify_opts()) ::
          {:ok, attachment_id :: String.t()} | {:error, :expired_or_invalid}
  def verify(token, tenant_id, opts \\ [])

  def verify(token, tenant_id, opts) when is_binary(token) and is_list(opts) do
    now = current_time(opts)

    with [payload_b64, signature_b64] <- String.split(token, ".", parts: 2),
         {:ok, payload} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, signature} <- Base.url_decode64(signature_b64, padding: false),
         {:ok,
          %{"attachment_id" => attachment_id, "expires_at" => expires_at, "key_id" => key_id}}
         when is_binary(attachment_id) and is_integer(expires_at) and is_integer(key_id) <-
           Jason.decode(payload),
         {:ok, tenant_slug} <- resolve_tenant_slug(tenant_id),
         {:ok, signing_key} <- resolve_signing_key(tenant_slug, key_id, tenant_id),
         true <- :crypto.hash_equals(sign(signing_key, payload), signature),
         true <- expires_at > DateTime.to_unix(now) do
      {:ok, attachment_id}
    else
      _ -> {:error, :expired_or_invalid}
    end
  end

  def verify(_token, _tenant_id, _opts), do: {:error, :expired_or_invalid}

  # ── private ──────────────────────────────────────────────────────────────

  defp current_time(opts), do: Keyword.get(opts, :now, &DateTime.utc_now/0).()

  defp link_expiry_seconds, do: 300

  defp resolve_tenant_slug(tenant_id) do
    case Identity.get_tenant(tenant_id) do
      {:ok, %{slug: slug}} -> {:ok, slug}
      {:error, :not_found} -> {:error, :invalid_tenant}
    end
  end

  # Get-or-create the tenant's link-signing secret in one pass: try the
  # unpinned reference first (covers the common case -- a secret already
  # exists), and only fall back to creating one on a genuine :not_found.
  # `resolve/2` already returns both the plaintext and the key_id it
  # resolved, so no second resolve call is needed once a secret exists.
  defp get_or_create_signing_key(tenant_id, tenant_slug) do
    case Secrets.resolve(unpinned_reference(tenant_slug),
           tenant_id: tenant_id,
           consumer: :generic
         ) do
      {:ok, %{plaintext: plaintext, key_id: key_id}} ->
        {:ok, key_id, plaintext}

      {:error, :not_found} ->
        create_signing_key(tenant_id)

      {:error, reason} ->
        {:error, {:secret_write_failed, reason}}
    end
  end

  defp create_signing_key(tenant_id) do
    plaintext = :crypto.strong_rand_bytes(32)

    case Secrets.put(%{
           tenant_id: tenant_id,
           namespace: @link_secret_namespace,
           name: @link_secret_name,
           purpose: :generic,
           plaintext: plaintext,
           created_by: "system:attachment_links.issue"
         }) do
      {:ok, %{key_id: key_id}} ->
        {:ok, key_id, plaintext}

      {:error, reason} ->
        {:error, {:secret_write_failed, reason}}
    end
  end

  defp resolve_signing_key(tenant_slug, key_id, tenant_id) do
    case Secrets.resolve(pinned_reference(tenant_slug, key_id),
           tenant_id: tenant_id,
           consumer: :generic
         ) do
      {:ok, %{plaintext: plaintext}} -> {:ok, plaintext}
      {:error, _reason} -> {:error, :expired_or_invalid}
    end
  end

  defp unpinned_reference(tenant_slug) do
    "sec://tenant/#{tenant_slug}/#{@link_secret_namespace}/#{@link_secret_name}"
  end

  defp pinned_reference(tenant_slug, key_id) do
    "sec://tenant/#{tenant_slug}/#{@link_secret_namespace}/#{@link_secret_name}##{key_id}"
  end

  # design §2.2 step 6 / §2.3 step 5 -- sign the exact raw payload bytes,
  # same "sign the exact bytes sent/stored" discipline
  # `Letflow.Webhooks.sign/2` already establishes for its own HMAC.
  defp sign(signing_key, payload) do
    :crypto.mac(:hmac, :sha256, signing_key, payload)
  end
end
