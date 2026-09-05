defmodule Letflow.Repository.Canonicaliser do
  @moduledoc """
  Computes the canonical byte form and content hash for the content-addressed
  artifact store (REPO-04, REQ-202). See
  `lib/letflow/design/req202-artifact-repository.md` §3 for the full design
  this module implements.

  ## A second, deliberately separate canonicaliser exists

  A second, deliberately separate canonicaliser exists at
  `Letflow.Definitions.PromotionDigest`
  (`lib/letflow/definitions/promotion_digest.ex`, REQ-036). That module's
  `canonicalize/1` does NOT normalize numbers -- an integer-valued float and
  its corresponding integer hash differently there. This module DOES
  normalize numbers. The two must never be merged into one shared
  canonicalization function: doing so would change `PromotionDigest`'s digest
  output for every plan whose digest is already stored, breaking
  `verify_digest/2` (INV-PRM-5) against those stored values.

  PROVENANCE (historical, not current decision authority):
  Concretely: `PromotionDigest.canonicalize/1`'s final clause passes every
  non-map, non-list, non-atom value through completely unchanged, so `2.0`
  and `2` canonicalize and hash differently there today. REPO-04 requires the
  opposite -- an integer-valued float must serialize identically to the
  corresponding bare integer, per R-Co's `canonicaliser.zig` (L32,
  L121-123). Adding number normalization to `PromotionDigest.canonicalize/1`
  would silently change the digest of every promotion plan already computed
  and stored. This is the concrete, mechanical reason the two canonicalisers
  are separate modules in separate namespaces (`Letflow.Repository.*` here,
  `Letflow.Definitions.*` there) rather than one parameterized module.

  ## Canonicalization rules (§3.4, normative)

  1. **Object keys sorted** -- recursively, every JSON object's keys are
     ordered (`Enum.sort/1` on the key list, rebuilt as a
     `Jason.OrderedObject`), so two JSON texts differing only in key order
     produce byte-identical canonical output.
  2. **No insignificant whitespace** -- `Jason.encode!/1`'s default compact
     output.
  3. **Numbers normalized:**
     - An integer, or a float with no fractional part (e.g. `2.0`, `3.0e2`),
       is serialized with no decimal point and no exponent form -- i.e.
       identically to the equivalent bare integer (`2`, `300`). Implemented
       by converting any integer-valued float to a plain `integer()` before
       encoding, so `Jason.encode!/1` emits it exactly as it would emit that
       integer.
     - **OQ-1, resolved:** a genuinely fractional float (e.g. `2.5`) is
       passed through unchanged into `Jason.encode!/1` -- i.e. Jason's own
       default float encoder (Erlang's shortest-round-trip decimal
       algorithm) is this module's fixed canonical form for fractional
       numbers. REQ-202's text and the R-Co citations available to this
       design specify the integer-valued-float case only; this module picks
       Jason's existing default as the one fixed, documented rule for the
       fractional case rather than inventing a second, independent
       formatting algorithm. This codebase's artifact content
       (`definition`/`form`/`schema`/`service_catalog`/`script`/`module`/
       `scenario` payloads) is not expected to carry floats in the
       exponential-notation magnitude range; if that need arises later, a
       fixed decimal-expansion rule should be added then, not assumed today.
  4. **Arrays are not reordered** -- array element order is significant
     content, same principle `PromotionDigest.canonicalize/1` already
     applies.
  5. **Binary (non-JSON) content is hashed by byte identity** -- see below.

  ## OQ-3, resolved: which content types are treated as JSON

  Only the exact string `"application/json"` routes through JSON
  canonicalization. No parameterized form (`"application/json;
  charset=utf-8"`) and no `+json` structured-syntax suffix is treated as
  JSON by this module -- the narrowest reading, per the design's own
  recommendation absent further guidance. Silently treating an unlisted
  content type as JSON risks canonicalizing content the submitter intended
  as opaque binary; any other `content_type` value is hashed by byte
  identity (§3.5).

  ## Byte identity for non-JSON content (§3.5)

  PROVENANCE (historical, not current decision authority):
  For any `content_type` other than the exact string `"application/json"`,
  `canonicalize_content/2` performs no transformation whatsoever -- the
  canonical form is the submitted bytes, verbatim, so `content_hash/1`'s
  output is a plain SHA-256 of exactly what was submitted (AC4). This rule
  originates in R-Co's `canonicaliser.zig` header and REPO-04
  cross-references WASM-05 for it; Letflow's WASM-related work (out of this
  requirement's scope) inherits this same rule rather than this module
  re-deriving it independently.
  """

  @type canonical_form :: binary()

  @json_content_type "application/json"

  @doc """
  Content-type-dispatching entry point. If `content_type` is exactly
  `"application/json"`, decodes `raw_bytes` with `Jason.decode/1`, applies
  the canonicalization rules above, and re-encodes; a `raw_bytes` value that
  fails to decode as JSON under that content type is
  `{:error, :invalid_json}`. For any other `content_type`, returns
  `{:ok, raw_bytes}` unchanged (byte-identity) -- always `{:ok, _}` in that
  branch, since no decoding is attempted.
  """
  @spec canonicalize_content(content_type :: String.t(), raw_bytes :: binary()) ::
          {:ok, canonical_form()} | {:error, :invalid_json}
  def canonicalize_content(@json_content_type, raw_bytes) when is_binary(raw_bytes) do
    case Jason.decode(raw_bytes) do
      {:ok, decoded} ->
        canonical =
          decoded
          |> canonicalize()
          |> Jason.encode!()

        {:ok, canonical}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  def canonicalize_content(_content_type, raw_bytes) when is_binary(raw_bytes) do
    {:ok, raw_bytes}
  end

  @doc """
  `:crypto.hash(:sha256, canonical_form)`, returning the raw 32-byte digest
  (not hex-encoded -- this is what `repository_artifacts.content_hash`,
  typed `:binary`, stores directly, unlike
  `PromotionDigest.compute_plan_digest/1`'s hex-string return, which serves a
  different consumer: a JSON-embeddable plan-digest field, not a binary
  primary key).
  """
  @spec content_hash(canonical_form()) :: binary()
  def content_hash(canonical_form) when is_binary(canonical_form) do
    :crypto.hash(:sha256, canonical_form)
  end

  # --- canonicalize/1 (§3.4) -------------------------------------------------

  @spec canonicalize(term()) :: term()
  defp canonicalize(value) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key -> {key, canonicalize(Map.get(value, key))} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(value) when is_list(value) do
    Enum.map(value, &canonicalize/1)
  end

  # Integer-valued float -> plain integer, so Jason emits it with no
  # decimal point and no exponent form (rule 3, integer-valued case).
  defp canonicalize(value) when is_float(value) do
    truncated = trunc(value)

    if truncated == value do
      truncated
    else
      # Genuinely fractional -- passed through unchanged (rule 3, OQ-1).
      value
    end
  end

  defp canonicalize(value), do: value
end
