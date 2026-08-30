defmodule Letflow.Secrets.Redaction do
  @moduledoc """
  Log/metadata redaction for secret-shaped values. See
  `lib/letflow/design/req190-secrets-core.md` §6.1. Pure functions, no
  process, no dependency on `Letflow.Secrets`/`Letflow.Repo` — this module
  is called from `Letflow.Application.start/2`'s `:logger` filter
  registration (§6.2) on the metadata map of every log event, so it must
  stay cheap and side-effect-free.

  Redaction keys on the field NAME only. A secret value placed under a key
  this module does not recognize as sensitive (a typo, a new call site using
  an unlisted key name, or a value nested under a generic key like `data`)
  is NOT caught and will appear in log output in plaintext. This module
  provides no content-based detection of secret-shaped values — it is a
  name-based denylist, not a guarantee.
  """

  @sensitive_exact_keys ~w(authorization password password_hash token access_token
    refresh_token bootstrap_token api_token secret client_secret credential
    credentials set-cookie cookie)

  @sensitive_suffixes ~w(_token _secret _password _credential)

  @redacted "[REDACTED]"

  @doc """
  Recursively walks `map` (and any nested map, or list of maps) and, for
  every key (string or atom, compared case-insensitively against
  `@sensitive_exact_keys` and `@sensitive_suffixes`), replaces the
  corresponding value with the literal string `"[REDACTED]"`. The key
  itself is always kept, unmodified. A non-matching key's value is
  recursed into if it is itself a map or a list of maps, otherwise left
  as-is.
  """
  @spec redact_map(map()) :: map()
  def redact_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, redact_value(value)}
      end
    end)
  end

  defp redact_value(value) when is_map(value), do: redact_map(value)

  defp redact_value(value) when is_list(value) do
    Enum.map(value, fn
      item when is_map(item) -> redact_map(item)
      item -> item
    end)
  end

  defp redact_value(value), do: value

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    Enum.member?(@sensitive_exact_keys, normalized) or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(normalized, &1))
  end

  @doc """
  Renders a `sec://tenant/...` reference for logging with the `#<key_id>`
  segment masked: `sec://tenant/<tenant>/<namespace>/<name>#***` if `reference`
  has a `#<key_id>` suffix, or `reference` unchanged (no `#` segment to mask)
  if it is already unpinned. Distinct from `redact_map/1` — this operates on
  a single reference *string*, not a map, because a reference string is not
  itself secret material (it names *where* a secret is, not the secret's
  value); only the `key_id` portion is masked, not the whole reference
  withheld.
  """
  @spec render_reference(reference :: String.t()) :: String.t()
  def render_reference(reference) when is_binary(reference) do
    case String.split(reference, "#", parts: 2) do
      [base, _key_id] -> base <> "#***"
      [base] -> base
    end
  end
end
